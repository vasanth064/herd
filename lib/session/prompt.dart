import 'dart:convert';

enum PromptKind { question, approval, plan, menu, fallback }

class PromptOption {
  final String label;
  final String? description;
  const PromptOption(this.label, [this.description]);
}

/// One thing to send: herdr key names, or literal text.
class KeyStep {
  final List<String>? keys;
  final String? text;
  const KeyStep.keys(this.keys) : text = null;
  const KeyStep.text(this.text) : keys = null;
  @override
  String toString() => keys != null ? 'keys:${keys!.join(',')}' : 'text:$text';
}

/// A menu Claude Code is showing in the pane right now, parsed from the
/// visible screen. Answering re-reads the screen and compares [id] first, so a
/// card that went stale cannot press keys into a different prompt.
class ScreenPrompt {
  final PromptKind kind;
  final String title;
  final String question;
  final String? body;
  final List<PromptOption> options;
  final int? customIndex;
  final int selected;
  final bool multiSelect;

  /// Fallback menus answer by typing the row number instead of walking to it.
  final bool digitKeys;

  ScreenPrompt({
    required this.kind,
    required this.title,
    required this.question,
    this.body,
    required this.options,
    this.customIndex,
    this.selected = 0,
    this.multiSelect = false,
    this.digitKeys = false,
  });

  String get id => jsonEncode([
    kind.name,
    title,
    question,
    body,
    [
      for (final o in options) [o.label, o.description],
    ],
    customIndex,
    multiSelect,
  ]).hashCode.toRadixString(36);

  List<KeyStep> answer(int i) {
    if (digitKeys) return [KeyStep.text('${i + 1}')];
    if (kind == PromptKind.fallback) {
      return [
        KeyStep.keys([options[i].label == 'Esc' ? 'esc' : 'enter']),
      ];
    }
    return [
      KeyStep.keys([..._walk(i), 'enter']),
    ];
  }

  List<KeyStep> answerText(String text) {
    final c = customIndex;
    if (c == null || multiSelect) return const [];
    final t = text.trim();
    return [
      if (_walk(c).isNotEmpty) KeyStep.keys(_walk(c)),
      KeyStep.text(t),
      KeyStep.keys([kind == PromptKind.plan ? 'shift+tab' : 'enter']),
    ];
  }

  List<String> _walk(int to) {
    final d = to - selected;
    return List.filled(d.abs(), d > 0 ? 'down' : 'up');
  }
}

final _ansi = RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]');
final _divider = RegExp(r'^[\s╭╮╰╯├┤┬┴┼─━═╌▔]+$');
final _solidRule = RegExp(r'^[─━]{8,}$');
final _row = RegExp(r'^\s*([›>❯])?\s*(\d+)\.\s+(.+)$');
final _questionHint = RegExp(
  r'enter to select.*(?:↑/↓|tab/arrow keys) to navigate.*esc to cancel',
  caseSensitive: false,
);
final _approvalTail = RegExp(r'esc to cancel', caseSensitive: false);
final _confirmHint = RegExp(
  r'enter to confirm.*esc to (?:cancel|exit|go back)',
  caseSensitive: false,
);
final _hintLine = RegExp(
  r'esc to (?:cancel|exit|go back)|enter to (?:select|confirm)',
  caseSensitive: false,
);
final _yn = RegExp(r'\(y/n\)', caseSensitive: false);

String _clean(String l) {
  var s = l.replaceAll(_ansi, '').trimRight();
  s = s.replaceFirst(RegExp(r'^\s*│'), '').replaceFirst(RegExp(r'│\s*$'), '');
  return s.trim();
}

class _Row {
  final int line;
  final int n;
  final bool cursor;
  String label;
  String? description;
  _Row(this.line, this.n, this.cursor, this.label);
}

/// Numbered rows ending above [end], as the last run numbered 1..n.
List<_Row> _rows(List<String> lines, int end) {
  final all = <_Row>[];
  for (var i = 0; i < end; i++) {
    final m = _row.firstMatch(lines[i]);
    if (m == null) continue;
    final n = int.parse(m.group(2)!);
    if (n == 1) all.clear();
    if (n != all.length + 1) {
      all.clear();
      if (n != 1) continue;
    }
    all.add(_Row(i, n, m.group(1) != null, m.group(3)!.trim()));
  }
  for (var k = 0; k < all.length; k++) {
    final next = k + 1 < all.length ? all[k + 1].line : end;
    final extra = <String>[];
    for (var i = all[k].line + 1; i < next; i++) {
      final t = lines[i];
      if (t.isEmpty || _divider.hasMatch(t) || _hintLine.hasMatch(t)) break;
      extra.add(t);
    }
    if (extra.isNotEmpty) all[k].description = extra.join(' ');
  }
  return all;
}

int _lastMatch(List<String> lines, RegExp re, {int window = 6}) {
  for (var i = lines.length - 1; i >= 0 && i >= lines.length - window; i--) {
    final joined = [
      for (var k = i; k < lines.length && k < i + 3; k++) lines[k],
    ].join(' ');
    if (re.hasMatch(joined)) return i;
  }
  return -1;
}

String _textAbove(List<String> lines, int firstRow) {
  final out = <String>[];
  for (var i = firstRow - 1; i >= 0; i--) {
    final t = lines[i];
    if (t.isEmpty) {
      if (out.isEmpty) continue;
      break;
    }
    if (_divider.hasMatch(t)) break;
    out.insert(0, t);
  }
  return out.join(' ');
}

int _cursor(List<_Row> rows) {
  final i = rows.indexWhere((r) => r.cursor);
  return i < 0 ? 0 : i;
}

/// Parses the visible pane text. [blocked] enables the generic fallback for
/// menus no specific reader recognises.
ScreenPrompt? parsePrompt(String screen, {bool blocked = false}) {
  final lines = screen.split('\n').map(_clean).toList();
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  if (lines.isEmpty) return null;

  // AskUserQuestion
  final qh = _lastMatch(lines, _questionHint);
  if (qh >= 0) {
    final rows = _rows(lines, qh);
    if (rows.length >= 3 &&
        rows.last.label.startsWith('Chat about this') &&
        rows[rows.length - 2].label.startsWith('Type something')) {
      final opts = rows.sublist(0, rows.length - 2);
      final multi = opts.any((r) => RegExp(r'^\[[ xX✓✔]\]').hasMatch(r.label));
      final chip = lines
          .take(rows.first.line)
          .lastWhere(
            (l) => RegExp(r'^[←]?\s*[☐☒☑✔]').hasMatch(l),
            orElse: () => '',
          );
      return ScreenPrompt(
        kind: PromptKind.question,
        title: chip.replaceAll(RegExp(r'^[←\s☐☒☑✔]+'), '').split('  ').first,
        question: _textAbove(lines, rows.first.line),
        options: [
          for (final r in opts)
            PromptOption(
              r.label
                  .replaceFirst(RegExp(r'^\[[ xX✓✔]\]\s*'), '')
                  .replaceFirst(
                    RegExp(r'\s*\(Recommended\)$'),
                    ' (Recommended)',
                  ),
              r.description,
            ),
        ],
        customIndex: multi ? null : rows.length - 2,
        selected: _cursor(rows),
        multiSelect: multi,
      );
    }
  }

  // Plan approval
  final planQ = lines.lastIndexWhere(
    (l) => l.contains(
      'Claude has written up a plan and is ready to execute. Would you like to proceed?',
    ),
  );
  if (planQ >= 0) {
    final rows = _rows(
      lines,
      lines.length,
    ).where((r) => r.line > planQ).toList();
    if (rows.length >= 3) {
      final custom = rows.indexWhere((r) => r.label.startsWith('Tell Claude'));
      return ScreenPrompt(
        kind: PromptKind.plan,
        title: 'Plan',
        question: 'Proceed with the plan?',
        options: [for (final r in rows) PromptOption(r.label, r.description)],
        customIndex: custom < 0 ? null : custom,
        selected: _cursor(rows),
      );
    }
  }

  // Tool permission
  final ask = lines.lastIndexWhere(
    (l) => RegExp(r'^Do you want to .+\?$').hasMatch(l),
  );
  if (ask >= 0 && _lastMatch(lines, _approvalTail) > ask) {
    final rows = _rows(lines, lines.length).where((r) => r.line > ask).toList();
    if (rows.length >= 2) {
      final call = lines
          .sublist(0, ask)
          .lastIndexWhere((l) => l.startsWith('●'));
      var rule = -1;
      for (var i = call + 1; i < ask; i++) {
        if (_solidRule.hasMatch(lines[i])) {
          rule = i;
          break;
        }
      }
      if (rule < 0) {
        rule = lines.sublist(0, ask).lastIndexWhere(_solidRule.hasMatch);
      }
      final above = [
        for (final l
            in rule >= 0
                ? lines.sublist(rule + 1, ask)
                : lines.sublist(ask > 12 ? ask - 12 : 0, ask))
          if (l.isNotEmpty &&
              !l.startsWith('Tip:') &&
              !_divider.hasMatch(l) &&
              l != 'This command requires approval')
            l,
      ];
      final title = above.isEmpty ? 'Permission' : above.first;
      final body = above.skip(1).join('\n');
      for (final r in rows) {
        if (r.description != null) {
          r.label = '${r.label} ${r.description}';
        }
        r.description = null;
      }
      return ScreenPrompt(
        kind: PromptKind.approval,
        title: title,
        question: lines[ask],
        body: body.isEmpty ? null : body,
        options: [for (final r in rows) PromptOption(r.label)],
        selected: _cursor(rows),
      );
    }
  }

  // Unnumbered confirm menus (folder trust and similar)
  final ch = _lastMatch(lines, _confirmHint);
  if (ch >= 0) {
    final opts = <String>[];
    var sel = 0;
    var first = ch;
    for (var i = ch - 1; i >= 0; i--) {
      final t = lines[i];
      if (t.isEmpty || _divider.hasMatch(t)) {
        if (opts.isEmpty) continue;
        break;
      }
      final c = RegExp(r'^[❯›>]\s*').hasMatch(t);
      opts.insert(0, t.replaceFirst(RegExp(r'^[❯›>]?\s*'), ''));
      first = i;
      if (c) sel = -opts.length;
    }
    if (opts.length >= 2 && opts.length <= 9) {
      final rule = lines.sublist(0, first).lastIndexWhere(_solidRule.hasMatch);
      final panel = [
        for (final l in lines.sublist(rule + 1, first))
          if (l.isNotEmpty) l,
      ];
      return ScreenPrompt(
        kind: PromptKind.menu,
        title: 'Confirm',
        question: panel.take(2).join(' '),
        body: panel.length > 2 ? panel.skip(2).join('\n') : null,
        options: [for (final o in opts) PromptOption(o)],
        selected: sel < 0 ? opts.length + sel : 0,
      );
    }
  }

  if (!blocked) return null;

  final rows = _rows(lines, lines.length);
  if (rows.length >= 2 &&
      rows.length <= 9 &&
      rows.last.line >= lines.length - 4) {
    return ScreenPrompt(
      kind: PromptKind.fallback,
      title: 'Waiting on you',
      question: _textAbove(lines, rows.first.line),
      options: [for (final r in rows) PromptOption(r.label, r.description)],
      digitKeys: true,
    );
  }
  final tail = lines.sublist(lines.length > 16 ? lines.length - 16 : 0);
  final yn = _yn.hasMatch(
    tail.sublist(tail.length > 2 ? tail.length - 2 : 0).join(" "),
  );
  return ScreenPrompt(
    kind: PromptKind.fallback,
    title: 'Waiting on you',
    question: tail
        .where((l) => l.isNotEmpty && !_divider.hasMatch(l))
        .join('\n'),
    options: yn
        ? const [PromptOption('Yes (y)'), PromptOption('No (n)')]
        : const [PromptOption('Enter'), PromptOption('Esc')],
    digitKeys: false,
  );
}

extension FallbackKeys on ScreenPrompt {
  /// y/n fallbacks type the letter; everything else is Enter or Esc.
  List<KeyStep> fallbackAnswer(int i) {
    final l = options[i].label;
    if (l.startsWith('Yes (y)')) return const [KeyStep.text('y')];
    if (l.startsWith('No (n)')) return const [KeyStep.text('n')];
    return answer(i);
  }
}
