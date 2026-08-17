import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'herdr.dart';
import 'models.dart';
import 'store.dart';

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final Store store;

  List<Profile> profiles = [];
  Map<String, String> knownHosts = {};
  ThemeMode themeMode = ThemeMode.dark;

  Profile? active;
  HerdrConnection? conn;
  ConnState state = ConnState.disconnected;
  String? error;

  List<AgentInfo> agents = [];
  List<SessionInfo> sessions = [];
  DateTime? lastPoll;
  bool pollStale = false;

  Timer? _poll;
  Timer? _retry;
  int _backoffMs = 1000;
  bool _foreground = true;

  /// Set by the UI to answer a first-time host key prompt.
  Future<bool> Function(String hostPort, String fingerprint)? hostKeyPrompt;

  AppState(this.store) {
    profiles = store.loadProfiles();
    knownHosts = store.loadKnownHosts();
    final t = store.themeMode();
    themeMode = t == 'light'
        ? ThemeMode.light
        : t == 'system'
            ? ThemeMode.system
            : ThemeMode.dark;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _retry?.cancel();
    conn?.close();
    super.dispose();
  }

  // ---- profiles -----------------------------------------------------------

  Future<void> saveProfile(Profile p) async {
    final i = profiles.indexWhere((x) => x.id == p.id);
    if (i >= 0) {
      profiles[i] = p;
    } else {
      profiles.add(p);
    }
    await store.saveProfiles(profiles);
    notifyListeners();
  }

  Future<void> deleteProfile(Profile p) async {
    profiles.removeWhere((x) => x.id == p.id);
    await store.deleteProfileSecrets(p);
    await store.saveProfiles(profiles);
    if (active?.id == p.id) await disconnect();
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    await store.setThemeMode(m.name);
    notifyListeners();
  }

  Future<void> forgetHost(String hostPort) async {
    knownHosts.remove(hostPort);
    await store.saveKnownHosts(knownHosts);
    notifyListeners();
  }

  // ---- connection ---------------------------------------------------------

  HerdrConnection _build(Profile p) => HerdrConnection(
        p,
        knownFingerprint: (hp) => knownHosts[hp],
        onNewHost: (hp, fp) async {
          final ok = await (hostKeyPrompt?.call(hp, fp) ?? Future.value(false));
          if (ok) {
            knownHosts[hp] = fp;
            await store.saveKnownHosts(knownHosts);
          }
          return ok;
        },
      );

  Future<void> connect(Profile p) async {
    _retry?.cancel();
    _backoffMs = 1000;
    active = p;
    error = null;
    state = ConnState.connecting;
    agents = [];
    notifyListeners();

    final c = _build(p);
    try {
      await c.connect(
        secret: await store.secret(p.secretKey),
        passphrase: await store.secret(p.passphraseKey),
      );
      conn = c;
      sessions = await c.sessions();
      if (p.sessionName == null && sessions.length == 1) {
        p.sessionName = sessions.first.name;
        await store.saveProfiles(profiles);
      }
      state = ConnState.connected;
      notifyListeners();
      for (final f in p.forwards.where((f) => f.autoStart)) {
        unawaited(startForward(f));
      }
      await refresh();
      _startPolling();
    } catch (e) {
      await c.close();
      conn = null;
      error = e.toString();
      state = ConnState.failed;
      notifyListeners();
      _scheduleRetry();
    }
  }

  Future<void> disconnect() async {
    _poll?.cancel();
    _retry?.cancel();
    await conn?.close();
    conn = null;
    active = null;
    agents = [];
    sessions = [];
    state = ConnState.disconnected;
    error = null;
    notifyListeners();
  }

  /// Only auth and a changed host key are terminal — everything else is a
  /// network blip worth retrying.
  void _scheduleRetry() {
    final p = active;
    if (p == null) return;
    if (error != null &&
        (error!.contains('Host key') || error!.contains('key changed'))) {
      return;
    }
    _retry?.cancel();
    _retry = Timer(Duration(milliseconds: _backoffMs), () {
      _backoffMs = min(_backoffMs * 2, 30000);
      if (_foreground) connect(p);
    });
  }

  void _startPolling() {
    _poll?.cancel();
    final ms = active?.pollMs ?? 2000;
    _poll = Timer.periodic(Duration(milliseconds: ms), (_) => refresh());
  }

  Future<void> refresh() async {
    final c = conn;
    if (c == null || !c.isConnected) return;
    try {
      final next = await c.agents();
      // Don't rebuild the list when nothing moved.
      final same = next.length == agents.length &&
          List.generate(next.length, (i) => i).every((i) =>
              next[i].paneId == agents[i].paneId &&
              next[i].status == agents[i].status &&
              next[i].revision == agents[i].revision &&
              next[i].title == agents[i].title);
      agents = next;
      lastPoll = DateTime.now();
      final wasStale = pollStale;
      pollStale = false;
      if (!same || wasStale) notifyListeners();
    } catch (e) {
      if (!pollStale) {
        pollStale = true;
        notifyListeners();
      }
      if (!(conn?.isConnected ?? false)) {
        state = ConnState.failed;
        error = e.toString();
        notifyListeners();
        _scheduleRetry();
      }
    }
  }

  Future<void> selectSession(String name) async {
    final p = active;
    if (p == null) return;
    p.sessionName = name;
    await store.saveProfiles(profiles);
    agents = [];
    notifyListeners();
    await refresh();
  }

  // ---- forwards -----------------------------------------------------------

  bool forwardActive(ForwardRule r) => conn?.forwardActive(r) ?? false;

  Future<String?> startForward(ForwardRule r) async {
    try {
      await conn?.startForward(r);
      notifyListeners();
      return null;
    } catch (e) {
      return 'Could not bind port ${r.port}: $e';
    }
  }

  Future<void> stopForward(ForwardRule r) async {
    await conn?.stopForward(r);
    notifyListeners();
  }

  // ---- lifecycle ----------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      final p = active;
      if (p != null && !(conn?.isConnected ?? false)) {
        _backoffMs = 1000;
        connect(p);
      } else if (p != null) {
        _startPolling();
        refresh();
      }
    } else if (state == AppLifecycleState.paused) {
      _foreground = false;
      _poll?.cancel();
      _retry?.cancel();
    }
  }
}
