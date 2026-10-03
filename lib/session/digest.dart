import 'dart:convert';

enum StepStatus { todo, now, done }

class SessionStep {
  final String id;
  String subject;
  String? activeForm;
  StepStatus state;
  SessionStep(
    this.id,
    this.subject, {
    this.activeForm,
    this.state = StepStatus.todo,
  });
}

class FileRef {
  final String path;
  DateTime at;
  int edits;
  bool created;
  FileRef(this.path, this.at, {this.edits = 0, this.created = false});

  String get name => path.split('/').last;
  String get dir {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }

  String get ext {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toUpperCase();
  }
}

enum LinkKind { pr, ci, web, local }

class LinkRef {
  final String url;
  final DateTime at;
  LinkRef(this.url, this.at);

  int? get localPort {
    final m = RegExp(r'^https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d+)')
        .firstMatch(url);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  LinkKind get kind {
    if (localPort != null) return LinkKind.local;
    if (RegExp(r'/pull/\d+|/pullrequest/\d+|/merge_requests/\d+')
        .hasMatch(url)) {
      return LinkKind.pr;
    }
    if (RegExp(r'/actions/runs/|/_build/results|/pipelines/').hasMatch(url)) {
      return LinkKind.ci;
    }
    return LinkKind.web;
  }

  String get label {
    final pr = RegExp(r'/pull(?:request)?/(\d+)').firstMatch(url);
    if (pr != null) return 'PR #${pr.group(1)}';
    final u = Uri.tryParse(url);
    if (u == null) return url;
    final p = u.path.length > 1 ? u.path : '';
    return '${u.host}${u.hasPort ? ':${u.port}' : ''}$p';
  }
}

class AskOption {
  final String label;
  final String? description;
  const AskOption(this.label, this.description);
}

/// A pending AskUserQuestion call: structured text for the card, while the
/// keys that answer it come from what is actually on screen.
class PendingAsk {
  final String id;
  final String question;
  final String header;
  final List<AskOption> options;
  final bool multiSelect;
  const PendingAsk(
    this.id,
    this.question,
    this.header,
    this.options,
    this.multiSelect,
  );
}

enum ChatRole { you, claude, tool }

class ChatLine {
  final ChatRole role;
  final String text;
  final DateTime at;
  const ChatLine(this.role, this.text, this.at);
}

/// Everything the summary screen shows, folded incrementally from a Claude
/// Code session log.
class Digest {
  /// A subagent's own log, where every record is a sidechain.
  final bool sidechain;
  Digest({this.sidechain = false});

  String? title;
  String? firstPrompt;
  String? lastPrompt;
  String? model;
  int contextTokens = 0;
  int compactions = 0;
  DateTime? lastActivity;

  /// What the latest tool call touched, shown under the current step.
  String? activity;

  /// Claude's last text since your latest prompt: the turn's answer.
  String? lastReply;

  final List<ChatLine> _chat = [];

  /// Your prompts, kept apart so tool calls never push them out of the ring.
  final List<String> _asked = [];
  static const _chatCap = 200;
  List<ChatLine> get chat => List.unmodifiable(_chat);

  void _say(ChatRole role, String text, DateTime at) {
    _chat.add(ChatLine(role, text, at));
    if (_chat.length > _chatCap) _chat.removeAt(0);
  }

  final Map<String, SessionStep> _steps = {};
  final Map<String, _PendingCreate> _creating = {};
  final Map<String, FileRef> _files = {};
  final Map<String, LinkRef> _links = {};
  final Map<String, PendingAsk> _asks = {};
  final Set<String> taskMentions = {};

  List<SessionStep> get steps => _steps.values.toList();

  /// Your recent asks as steps, for sessions that never call TaskCreate: each
  /// is done once you have moved on to the next.
  List<SessionStep> turns({required bool working}) {
    final recent = _asked.length > 6
        ? _asked.sublist(_asked.length - 6)
        : _asked;
    return [
      for (var i = 0; i < recent.length; i++)
        SessionStep(
          'turn$i',
          _headline(recent[i]),
          state: i < recent.length - 1 || !working
              ? StepStatus.done
              : StepStatus.now,
        ),
    ];
  }

  static String _headline(String t) {
    final line = t.trim().split('\n').first.trim();
    return line.length > 90 ? '${line.substring(0, 90)}…' : line;
  }

  List<FileRef> get files =>
      _files.values.toList()..sort((a, b) => b.at.compareTo(a.at));
  List<LinkRef> get links =>
      _links.values.toList()..sort((a, b) => b.at.compareTo(a.at));
  PendingAsk? get pendingAsk => _asks.isEmpty ? null : _asks.values.last;

  String get goal => title ?? firstPrompt ?? '';

  void forgetAsks() => _asks.clear();

  static final _url = RegExp(r'''https?://[^\s<>()\[\]`'"*]+''');
  static final _task = RegExp(r'\bT(\d{1,5})\b');

  /// Feeds complete JSONL lines. Unparseable lines are skipped: the first
  /// line of a tail read usually starts mid-record.
  void addLines(Iterable<String> lines) {
    for (final l in lines) {
      if (l.isEmpty || l[0] != '{') continue;
      try {
        _add(jsonDecode(l) as Map<String, dynamic>);
      } catch (_) {}
    }
  }

  void _add(Map<String, dynamic> j) {
    if (j['isSidechain'] == true && !sidechain) return;
    final ts = DateTime.tryParse(j['timestamp'] as String? ?? '');
    final at = ts ?? lastActivity ?? DateTime.now();
    if (ts != null) lastActivity = ts;

    switch (j['type']) {
      case 'ai-title':
        title = j['aiTitle'] as String? ?? title;
        return;
      case 'last-prompt':
        final p = (j['lastPrompt'] as String?)?.trim();
        if (p != null && p.isNotEmpty) lastPrompt = p;
        return;
      case 'system':
        if (j['subtype'] == 'compact_boundary') compactions++;
        return;
      case 'user':
        _user(j, at);
        return;
      case 'assistant':
        _assistant(j, at);
        return;
    }
  }

  void _user(Map<String, dynamic> j, DateTime at) {
    final content = (j['message'] as Map?)?['content'];
    if (content is String) {
      _prompt(content, j, at);
      return;
    }
    if (content is! List) return;
    for (final x in content.cast<Map>()) {
      if (x['type'] == 'text') _prompt(x['text'] as String? ?? '', j, at);
      if (x['type'] != 'tool_result') continue;
      final id = x['tool_use_id'] as String?;
      _asks.remove(id);
      final pending = _creating.remove(id);
      if (pending != null) {
        final task = (j['toolUseResult'] as Map?)?['task'] as Map?;
        final tid =
            task?['id']?.toString() ??
            RegExp(r'#(\d+)').firstMatch('${x['content']}')?.group(1);
        if (tid != null) {
          _steps[tid] = SessionStep(
            tid,
            pending.subject,
            activeForm: pending.active,
          );
        }
      }
    }
  }

  void _prompt(String text, Map<String, dynamic> j, DateTime at) {
    final t = text.trim();
    if (t.isEmpty || j['isMeta'] == true || t.startsWith('<')) return;
    if (t.startsWith('This session is being continued')) return;
    if (t.startsWith('[Request interrupted')) return;
    firstPrompt ??= t;
    lastPrompt = t;
    lastReply = null;
    _say(ChatRole.you, t, at);
    if (!t.startsWith('/')) {
      _asked.add(t);
      if (_asked.length > 20) _asked.removeAt(0);
    }
    _mentions(t);
  }

  void _assistant(Map<String, dynamic> j, DateTime at) {
    final msg = j['message'] as Map? ?? const {};
    final m = msg['model'] as String?;
    if (m != null && m != '<synthetic>') model = m;
    final u = msg['usage'] as Map?;
    if (u != null) {
      final n =
          ((u['input_tokens'] ?? 0) as num) +
          ((u['cache_creation_input_tokens'] ?? 0) as num) +
          ((u['cache_read_input_tokens'] ?? 0) as num);
      if (n > 0) contextTokens = n.toInt();
    }
    final content = msg['content'];
    if (content is! List) return;
    for (final x in content.cast<Map>()) {
      if (x['type'] == 'text') {
        final t = x['text'] as String? ?? '';
        for (final mm in _url.allMatches(t)) {
          final url = mm.group(0)!.replaceAll(RegExp(r'[.,;:!?]+$'), '');
          _links[url] = LinkRef(url, at);
        }
        _mentions(t);
        if (t.trim().isNotEmpty) {
          lastReply = t.trim();
          _say(ChatRole.claude, t.trim(), at);
        }
      }
      if (x['type'] == 'tool_use') _tool(x, at);
    }
  }

  void _tool(Map x, DateTime at) {
    final id = x['id'] as String? ?? '';
    final input = (x['input'] as Map?) ?? const {};
    activity = switch (x['name']) {
      'Edit' || 'MultiEdit' || 'Write' =>
        'Editing ${(input['file_path'] as String? ?? '').split('/').last}',
      'Read' =>
        'Reading ${(input['file_path'] as String? ?? '').split('/').last}',
      'Bash' => 'Running ${_short(input['command'] as String? ?? '')}',
      'Agent' || 'Task' => 'Delegating: ${input['description'] ?? ''}',
      _ => activity,
    };
    final name = x['name'] as String? ?? 'tool';
    if (!name.startsWith('Task') && name != 'TodoWrite') {
      _say(ChatRole.tool, _toolLine(name, input), at);
    }
    switch (x['name']) {
      case 'TaskCreate':
        _creating[id] = _PendingCreate(
          input['subject'] as String? ?? 'Step',
          input['activeForm'] as String?,
        );
      case 'TaskUpdate':
        final s = _steps[input['taskId']?.toString()];
        if (s == null) return;
        if (input['subject'] is String) s.subject = input['subject'] as String;
        if (input['activeForm'] is String) {
          s.activeForm = input['activeForm'] as String;
        }
        switch (input['status']) {
          case 'in_progress':
            s.state = StepStatus.now;
            activity = null;
          case 'completed':
            s.state = StepStatus.done;
          case 'pending':
            s.state = StepStatus.todo;
          case 'deleted':
            _steps.remove(s.id);
        }
      case 'TodoWrite':
        final todos = input['todos'];
        if (todos is! List) return;
        _steps.clear();
        var i = 0;
        for (final t in todos.cast<Map>()) {
          final st = switch (t['status']) {
            'completed' => StepStatus.done,
            'in_progress' => StepStatus.now,
            _ => StepStatus.todo,
          };
          final key = 'todo${i++}';
          _steps[key] = SessionStep(
            key,
            t['content'] as String? ?? '',
            activeForm: t['activeForm'] as String?,
            state: st,
          );
        }
      case 'Write':
      case 'Edit':
      case 'MultiEdit':
      case 'NotebookEdit':
        final p = (input['file_path'] ?? input['notebook_path']) as String?;
        if (p == null) return;
        final f = _files.putIfAbsent(
          p,
          () => FileRef(p, at, created: x['name'] == 'Write'),
        );
        f.at = at;
        f.edits++;
      case 'AskUserQuestion':
        final qs = input['questions'];
        if (qs is! List || qs.isEmpty) return;
        final q = qs.first as Map;
        _asks[id] = PendingAsk(
          id,
          q['question'] as String? ?? '',
          q['header'] as String? ?? '',
          [
            for (final o in (q['options'] as List? ?? const []).cast<Map>())
              AskOption(
                o['label'] as String? ?? '',
                o['description'] as String?,
              ),
          ],
          q['multiSelect'] == true,
        );
    }
  }

  static String _toolLine(String name, Map input) {
    final file = (input['file_path'] as String? ?? '').split('/').last;
    return switch (name) {
      'Edit' || 'MultiEdit' => 'Edited $file',
      'Write' => 'Wrote $file',
      'Read' => 'Read $file',
      'Bash' => 'Ran ${_short(input['command'] as String? ?? '')}',
      'Grep' || 'Glob' => 'Searched ${input['pattern'] ?? ''}',
      'Agent' || 'Task' => 'Delegated: ${input['description'] ?? ''}',
      'AskUserQuestion' => 'Asked you a question',
      'WebFetch' ||
      'WebSearch' => 'Looked up ${input['url'] ?? input['query'] ?? ''}',
      _ => name,
    };
  }

  static String _short(String c) {
    final one = c.split('\n').first.trim();
    return one.length > 48 ? '${one.substring(0, 48)}…' : one;
  }

  void _mentions(String t) {
    for (final m in _task.allMatches(t)) {
      taskMentions.add(m.group(1)!);
    }
  }
}

class _PendingCreate {
  final String subject;
  final String? active;
  _PendingCreate(this.subject, this.active);
}

/// Context window for the usage ring. The log's model id omits the 1M
/// marker, so usage past 200k is the only sign of a 1M window.
int contextWindow(String? model, int tokens) =>
    (model?.contains('[1m]') ?? false) || tokens > 200000 ? 1000000 : 200000;

/// "claude-opus-5-5" -> "Opus 5.5".
String modelLabel(String? id) {
  if (id == null) return '';
  final m = RegExp(r'claude-(\w+)-(\d+)-(\d+)').firstMatch(id);
  if (m == null) return id;
  final n = m.group(1)!;
  return '${n[0].toUpperCase()}${n.substring(1)} ${m.group(2)}.${m.group(3)}';
}
