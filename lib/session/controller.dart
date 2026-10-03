import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../herdr.dart';
import '../models.dart';
import 'digest.dart';
import 'prompt.dart';

class Comment {
  final String quote;
  final String note;
  const Comment(this.quote, this.note);
}

/// A model and effort chosen together from one slider stop.
class Preset {
  final String name;
  final String model;
  final String modelArg;
  final String effort;
  const Preset(this.name, this.model, this.modelArg, this.effort);
}

const presets = [
  Preset('Instant', 'Haiku 4.5', 'haiku', 'low'),
  Preset('Fast', 'Sonnet 5.5', 'sonnet', 'medium'),
  Preset('Balanced', 'Opus 5.5', 'opus', 'medium'),
  Preset('Deep', 'Opus 5.5', 'opus', 'high'),
  Preset('Max', 'Fable 5.1', 'fable', 'max'),
];

const efforts = ['low', 'medium', 'high', 'max'];

class StalePromptException implements Exception {
  @override
  String toString() => 'The prompt changed on the host. Look again.';
}

/// Live state of one agent pane: its session log digest, the menu on its
/// screen, and the messages waiting to go to it. Polls only while a screen
/// holds it open.
class SessionController extends ChangeNotifier {
  final AppState app;
  final String paneId;

  SessionController(this.app, this.paneId) {
    queue = app.store.queue(paneId);
  }

  Digest digest = Digest();
  String? path;
  int _offset = 0;
  String screen = '';
  ScreenPrompt? prompt;
  late List<String> queue;
  final Map<String, List<Comment>> drafts = {};

  /// Subagents this session started, refreshed every few polls.
  List<SubAgent> subAgents = [];
  int _polls = 0;

  /// Host paths to prefix the next message with, as @references.
  final List<String> attachments = [];
  String? error;
  bool loaded = false;

  /// What the slider last sent; the log only records the model.
  String? effort;

  /// The host's Claude Code model picker.
  ClaudeModels catalog = const ClaudeModels([], {}, null);
  bool _catalogLoaded = false;

  /// The model label Claude Code's status line shows, e.g. "Opus 5.5 · Personal".
  String? currentLabel;
  static final _statusModel = RegExp(
    r'\[([^\]\n]+)\](?=\s+ctx:|[ \t]*$)',
    multiLine: true,
  );

  Timer? _timer;
  bool _busy = false;
  DateTime _resolvedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _screenHash = 0;

  AgentInfo? get agent =>
      app.agents.where((a) => a.paneId == paneId).firstOrNull;
  AgentStatus get status => agent?.status ?? AgentStatus.unknown;
  bool get working => status == AgentStatus.working;
  HerdrConnection? get _conn => app.conn;

  /// Claude Code's own figure from the status line when it shows one.
  int? statusContext;
  static final _statusCtx = RegExp(r'ctx:\s*(\d+)%');

  int get contextWindowSize {
    final id = currentOption?.id;
    if (id != null) return id.contains('[1m]') ? 1000000 : 200000;
    return contextWindow(digest.model, digest.contextTokens);
  }

  double get contextUsed {
    final s = statusContext;
    if (s != null) return (s / 100).clamp(0, 1);
    return (digest.contextTokens / contextWindowSize).clamp(0, 1);
  }

  /// The model label from Claude Code's status line, e.g. "Opus 5.5 · Personal".
  static String? statusModel(String screen) =>
      _statusModel.allMatches(screen).lastOrNull?.group(1);

  String get modelName => currentLabel ?? modelLabel(digest.model);

  ModelOption? get currentOption =>
      catalog.options.where((o) => o.label == currentLabel).firstOrNull;

  /// Effort from the phone if set, else the host's default for this model.
  String? get effortNow {
    final base = currentOption?.behavesAs ?? digest.model;
    return effort ?? catalog.effortByModel[base] ?? catalog.defaultEffort;
  }

  Preset? get preset {
    final base = modelName.split(' · ').first;
    return presets
        .where((p) => p.model == base && p.effort == effortNow)
        .firstOrNull;
  }

  void start() {
    _timer?.cancel();
    unawaited(poll());
    _timer = Timer.periodic(
      Duration(milliseconds: app.active?.pollMs ?? 2000),
      (_) => poll(),
    );
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    pause();
    super.dispose();
  }

  Future<void> poll() async {
    final c = _conn;
    if (_busy || c == null || !c.isConnected) return;
    _busy = true;
    try {
      // /clear and /resume start a new log, so the binding is re-checked.
      if (path == null ||
          DateTime.now().difference(_resolvedAt) >
              const Duration(seconds: 20)) {
        final p = await c.claudeTranscript(paneId);
        _resolvedAt = DateTime.now();
        if (p != path) {
          path = p;
          _offset = 0;
          digest = Digest();
        }
      }
      final r = await c.pollSession(path, _offset, paneId);
      var changed = !loaded;
      if (r.size >= 0) {
        if (r.start != _offset) digest = Digest();
        if (r.lines.isNotEmpty) {
          digest.addLines(r.lines);
          changed = true;
        }
        // History skips tool results, so its questions look unanswered.
        if (r.history) digest.forgetAsks();
        _offset = r.next;
      }
      if (!_catalogLoaded) {
        _catalogLoaded = true;
        catalog = await c.claudeModels();
        changed = true;
      }
      final h = r.screen.hashCode;
      if (h != _screenHash) {
        _screenHash = h;
        screen = r.screen;
        final pct = _statusCtx.allMatches(screen).lastOrNull?.group(1);
        if (pct != null && int.parse(pct) != statusContext) {
          statusContext = int.parse(pct);
          changed = true;
        }
        final label = statusModel(screen);
        if (label != null && label != currentLabel) {
          currentLabel = label;
          changed = true;
        }
        final next = parsePrompt(
          screen,
          blocked: status == AgentStatus.blocked,
        );
        if (next?.id != prompt?.id) changed = true;
        prompt = next;
      }
      if (path != null && _polls++ % 5 == 0) {
        final found = await c.subAgents(path!);
        if (found.length != subAgents.length ||
            found.any((a) => a.running) ||
            subAgents.any((a) => a.running)) {
          subAgents = found;
          changed = true;
        }
      }
      loaded = true;
      if (error != null) changed = true;
      error = null;
      await _flushQueue();
      if (changed) notifyListeners();
    } catch (e) {
      error = '$e';
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  /// The pane is free for a queued message when it is neither working nor
  /// showing a menu.
  Future<void> _flushQueue() async {
    if (queue.isEmpty || working || prompt != null) return;
    if (status != AgentStatus.idle && status != AgentStatus.done) return;
    final next = queue.removeAt(0);
    await app.store.setQueue(paneId, queue);
    await _conn?.say(paneId, next);
  }

  void attach(String hostPath) {
    attachments.add('@$hostPath');
    notifyListeners();
  }

  Future<void> send(String text, {bool now = false}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    if (working && !now) {
      queue.add(t);
      await app.store.setQueue(paneId, queue);
      notifyListeners();
      return;
    }
    await _conn?.say(paneId, t);
    digest.lastPrompt = t;
    notifyListeners();
    unawaited(Future.delayed(const Duration(milliseconds: 600), poll));
  }

  Future<void> sendQueued(int i) async {
    final t = queue.removeAt(i);
    await app.store.setQueue(paneId, queue);
    await send(t, now: true);
  }

  Future<String> takeQueued(int i) async {
    final t = queue.removeAt(i);
    await app.store.setQueue(paneId, queue);
    notifyListeners();
    return t;
  }

  Future<void> dropQueued(int i) async {
    queue.removeAt(i);
    await app.store.setQueue(paneId, queue);
    notifyListeners();
  }

  /// Re-reads the screen and refuses when the menu is no longer the one the
  /// card showed.
  Future<void> _answer(List<KeyStep> Function(ScreenPrompt) steps) async {
    final c = _conn;
    final shown = prompt;
    if (c == null || shown == null) return;
    final fresh = parsePrompt(
      (await c.pollSession(null, 0, paneId)).screen,
      blocked: status == AgentStatus.blocked,
    );
    if (fresh == null || fresh.id != shown.id) {
      prompt = fresh;
      notifyListeners();
      throw StalePromptException();
    }
    for (final s in steps(fresh)) {
      if (s.keys != null) {
        await c.paneKeys(paneId, s.keys!);
      } else {
        await c.sendText(paneId, s.text!);
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    prompt = null;
    notifyListeners();
    unawaited(Future.delayed(const Duration(milliseconds: 500), poll));
  }

  Future<void> answer(int i) => _answer(
    (p) => p.kind == PromptKind.fallback ? p.fallbackAnswer(i) : p.answer(i),
  );

  Future<void> answerText(String text) => _answer((p) => p.answerText(text));

  Future<void> stop() async => _conn?.paneKeys(paneId, ['esc']);

  /// [withEffort] false switches only the model: `/effort` also saves
  /// itself as that model's default for new sessions.
  Future<void> applyPreset(Preset p, {bool withEffort = true}) async {
    final o = catalog.options.where((o) => o.label == p.model).firstOrNull;
    await _conn?.say(paneId, '/model ${o?.id ?? p.modelArg}');
    if (withEffort) {
      effort = p.effort;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _conn?.say(paneId, '/effort ${p.effort}');
    }
    notifyListeners();
  }

  Future<void> setModel(String id) async {
    await _conn?.say(paneId, '/model $id');
    unawaited(Future.delayed(const Duration(seconds: 1), poll));
  }

  Future<void> setEffort(String e) async {
    effort = e;
    await _conn?.say(paneId, '/effort $e');
    notifyListeners();
  }

  Future<void> compact() => _conn!.say(paneId, '/compact');
  Future<void> clear() => _conn!.say(paneId, '/clear');

  Future<void> sendComments(String file) async {
    final d = drafts.remove(file) ?? const [];
    if (d.isEmpty) return;
    final b = StringBuffer('Review comments on $file:\n');
    for (var i = 0; i < d.length; i++) {
      b.writeln('${i + 1}. "${d[i].quote}" — ${d[i].note}');
    }
    await send(b.toString());
  }
}
