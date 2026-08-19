import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'herdr.dart';
import 'models.dart';
import 'native.dart';
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

  /// Auth and host-key failures don't heal on their own; retrying them just
  /// re-opens the prompt the user already answered.
  bool _fatal = false;

  Timer? _poll;
  Timer? _retry;
  int _backoffMs = 1000;

  /// Last seen status per pane, so only transitions raise a notification.
  final Map<String, AgentStatus> _seen = {};

  /// When each pane entered the status it is in — as far as this app has seen.
  /// A reconnect reseeds it, so it dates the sighting, not the agent's work.
  final Map<String, DateTime> _since = {};
  bool _seeded = false;

  /// Notification actions that arrived before there was a connection to run
  /// them on — a tap can land while the app is still starting up.
  final List<NotificationAction> _pending = [];
  bool _lostNotified = false;

  static const _connKey = 'connection';

  /// Set by the UI to answer a first-time host key prompt.
  Future<bool> Function(String hostPort, String fingerprint)? hostKeyPrompt;

  /// Set by the UI to answer a keyboard-interactive challenge.
  Future<List<String>?> Function(AuthChallenge)? challengePrompt;

  /// Set by the UI to show, and then drop, an auth-time notice from the server.
  void Function(String message)? showAuthNotice;
  void Function()? hideAuthNotice;

  /// Held so a notice raised before the UI exists — a reconnect on process
  /// start — is still shown once a screen registers the hooks.
  String? pendingAuthNotice;

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
    Native.listen();
    Native.onWake = () => unawaited(drainActions());
    unawaited(resumeLast());
  }

  /// Android can restart the process with no activity at all — from a
  /// notification action, or after reclaiming memory. Nothing else calls
  /// connect() in that case, so reconnect here or the app comes back inert.
  Future<void> resumeLast() async {
    if (active != null) return;
    final id = store.lastProfileId();
    if (id == null) return;
    final p = profiles.where((x) => x.id == id).firstOrNull;
    if (p != null) await connect(p);
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
        onChallenge: (c) async => challengePrompt?.call(c),
        onAuthNotice: _authNotice,
      );

  Future<void> connect(Profile p) async {
    _retry?.cancel();
    _backoffMs = 1000;
    active = p;
    error = null;
    _fatal = false;
    state = ConnState.connecting;
    agents = [];
    notifyListeners();

    // The old connection owns the listening sockets for its forwards. Dropping
    // it without closing leaves them bound, so every auto-started forward on
    // the new connection fails with "address already in use".
    await conn?.close();
    conn = null;

    final c = _build(p);
    try {
      await c.connect(
        secret: await store.secret(p.secretKey),
        passphrase: await store.secret(p.passphraseKey),
      );
      _authNotice(null);
      conn = c;
      sessions = await c.sessions();
      if (p.sessionName == null && sessions.length == 1) {
        p.sessionName = sessions.first.name;
        await store.saveProfiles(profiles);
      }
      state = ConnState.connected;
      _lostNotified = false;
      unawaited(store.setLastProfileId(p.id));
      unawaited(Native.cancel(_connKey));
      _syncService();
      notifyListeners();
      for (final f in p.forwards.where((f) => f.autoStart)) {
        unawaited(startForward(f));
      }
      await refresh();
      await drainActions();
      _startPolling();
    } catch (e) {
      _authNotice(null);
      await c.close();
      conn = null;
      error = e.toString();
      _fatal = (e is AuthException && !e.retryable) ||
          e is HostKeyChangedException;
      state = ConnState.failed;
      notifyListeners();
      _scheduleRetry();
    }
  }

  void _authNotice(String? message) {
    pendingAuthNotice = message;
    if (message == null) {
      hideAuthNotice?.call();
    } else {
      showAuthNotice?.call(message);
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
    _seen.clear();
    _since.clear();
    _seeded = false;
    unawaited(store.setLastProfileId(null));
    unawaited(Native.stopService());
    unawaited(Native.cancel(_connKey));
    notifyListeners();
  }

  /// Only auth and a changed host key are terminal — everything else is a
  /// network blip worth retrying.
  void _scheduleRetry() {
    final p = active;
    if (p == null || _fatal) return;
    if (!_lostNotified) {
      _lostNotified = true;
      unawaited(Native.notify(
        pane: _connKey,
        title: 'Herd lost its connection',
        text: 'Agents and forwarded ports are unreachable. Retrying…',
      ));
    }
    _retry?.cancel();
    _retry = Timer(Duration(milliseconds: _backoffMs), () {
      _backoffMs = min(_backoffMs * 2, 30000);
      connect(p);
    });
  }

  void _startPolling({int? ms}) {
    _poll?.cancel();
    final every = ms ?? active?.pollMs ?? 2000;
    _poll = Timer.periodic(Duration(milliseconds: every), (_) => refresh());
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
      await _notifyStatusChanges(next);
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

  /// How long this pane has held its status, or null before the first sighting.
  Duration? heldFor(String paneId) {
    final t = _since[paneId];
    return t == null ? null : DateTime.now().difference(t);
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
      _syncService();
      notifyListeners();
      return null;
    } catch (e) {
      return 'Could not bind port ${r.port}: $e';
    }
  }

  Future<void> stopForward(ForwardRule r) async {
    await conn?.stopForward(r);
    _syncService();
    notifyListeners();
  }

  // ---- background service and notifications -------------------------------

  /// The service runs for the whole connection, not just for forwards: a
  /// blocked agent has to reach the user while the app is closed too.
  void _syncService() {
    final p = active;
    if (p == null || state == ConnState.disconnected) {
      unawaited(Native.stopService());
      return;
    }
    final ports = p.forwards.where(forwardActive).map((f) => f.port).toList();
    final where = ports.isEmpty ? p.name : '${p.name} · ${ports.join(', ')}';
    unawaited(Native.startService(where));
  }

  Future<void> _notifyStatusChanges(List<AgentInfo> next) async {
    final live = <String>{};
    // The first snapshot of a connection is history, not news: an agent that
    // finished hours ago is still `done`, and announcing it reads as the app
    // shouting about old work every time it reconnects.
    final seeding = !_seeded;
    _seeded = true;

    for (final a in next) {
      live.add(a.paneId);
      final was = _seen[a.paneId];
      _seen[a.paneId] = a.status;
      if (was != a.status) _since[a.paneId] = DateTime.now();
      if (seeding || was == a.status) continue;
      switch (a.status) {
        case AgentStatus.blocked:
          final question = await conn?.agentQuestion(a.paneId);
          unawaited(Native.notify(
            pane: a.paneId,
            title: '${a.agent} is waiting · ${a.repo}',
            text: question ?? 'Waiting on your input.',
            keys: const ['1', '2', 'esc'],
            reply: true,
          ));
        case AgentStatus.done:
          unawaited(Native.notify(
            pane: a.paneId,
            title: '${a.agent} finished · ${a.repo}',
            text: a.title.isEmpty ? 'Task complete.' : a.title,
            reply: true,
          ));
        default:
          if (was == AgentStatus.blocked || was == AgentStatus.done) {
            unawaited(Native.cancel(a.paneId));
          }
      }
    }
    _seen.removeWhere((pane, _) => !live.contains(pane));
    _since.removeWhere((pane, _) => !live.contains(pane));
  }

  /// Runs whatever the user tapped on a notification. Anything that arrives
  /// without a connection is held rather than dropped — a swallowed keypress on
  /// a permission prompt looks exactly like the app ignoring them.
  Future<void> drainActions() async {
    final c = conn;
    // Leave them in the host queue until there is somewhere to send them:
    // taking them into a Dart list would lose them if the process dies first.
    if (c == null) return;
    _pending.addAll(await Native.takeActions());
    if (_pending.isEmpty) return;
    final todo = List.of(_pending);
    _pending.clear();
    for (final a in todo) {
      try {
        if (a.kind == 'text') {
          await c.prompt(a.pane, a.value);
        } else {
          await c.sendKeys(a.pane, [a.value]);
        }
      } catch (_) {
        _pending.add(a);
      }
    }
    await refresh();
  }

  // ---- lifecycle ----------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // A Tailscale browser check leaves a connect() in flight while the app is
      // in the background; starting a second one throws away the check.
      if (this.state == ConnState.connecting) return;
      final p = active;
      if (p != null && !(conn?.isConnected ?? false)) {
        _backoffMs = 1000;
        connect(p);
      } else if (p != null) {
        _startPolling();
        refresh();
      }
    } else if (state == AppLifecycleState.paused) {
      if (active == null) {
        _poll?.cancel();
        _retry?.cancel();
      } else {
        // Slower, but it must keep running: refresh() is what notices both a
        // dropped link and an agent that started waiting on the user.
        _startPolling(ms: 10000);
      }
    }
  }
}
