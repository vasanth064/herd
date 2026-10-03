import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/session/controller.dart';
import 'package:herdr_mobile/session/digest.dart';
import 'package:herdr_mobile/session/prompt.dart';

String _l(Map<String, dynamic> j) => jsonEncode(j);

Map<String, dynamic> _asst(
  List<Map<String, dynamic>> content, {
  String ts = '2026-10-02T10:00:00Z',
}) => {
  'type': 'assistant',
  'timestamp': ts,
  'message': {
    'model': 'claude-opus-5-5',
    'usage': {
      'input_tokens': 2,
      'cache_creation_input_tokens': 1000,
      'cache_read_input_tokens': 120000,
    },
    'content': content,
  },
};

Map<String, dynamic> _result(String id, String text, [Map? tur]) => {
  'type': 'user',
  'timestamp': '2026-10-02T10:00:01Z',
  'message': {
    'content': [
      {'type': 'tool_result', 'tool_use_id': id, 'content': text},
    ],
  },
  'toolUseResult': ?tur,
};

void main() {
  group('digest', () {
    test('folds goal, steps, files, links, asks and usage', () {
      final d = Digest()
        ..addLines([
          'partial line from a tail read"}',
          _l({
            'type': 'user',
            'message': {'content': 'build the summary screen'},
          }),
          _l({'type': 'ai-title', 'aiTitle': 'Session summary UI'}),
          _l(
            _asst([
              {
                'type': 'tool_use',
                'id': 'c1',
                'name': 'TaskCreate',
                'input': {
                  'subject': 'Parse transcript',
                  'activeForm': 'Parsing transcript',
                },
              },
              {
                'type': 'tool_use',
                'id': 'c2',
                'name': 'TaskCreate',
                'input': {'subject': 'Build UI'},
              },
            ]),
          ),
          _l(
            _result('c1', 'Task #1 created successfully: Parse transcript', {
              'task': {'id': '1'},
            }),
          ),
          _l(_result('c2', 'Task #2 created successfully: Build UI')),
          _l(
            _asst([
              {
                'type': 'tool_use',
                'id': 'u1',
                'name': 'TaskUpdate',
                'input': {'taskId': '1', 'status': 'completed'},
              },
              {
                'type': 'tool_use',
                'id': 'u2',
                'name': 'TaskUpdate',
                'input': {'taskId': '2', 'status': 'in_progress'},
              },
              {
                'type': 'tool_use',
                'id': 'w1',
                'name': 'Write',
                'input': {'file_path': '/r/docs/plan.md'},
              },
              {
                'type': 'tool_use',
                'id': 'e1',
                'name': 'Edit',
                'input': {'file_path': '/r/docs/plan.md'},
              },
              {
                'type': 'text',
                'text': 'Opened https://github.com/a/b/pull/41. Dev server on http://localhost:5173/x, see T243.',
              },
              {
                'type': 'tool_use',
                'id': 'q1',
                'name': 'AskUserQuestion',
                'input': {
                  'questions': [
                    {
                      'question': 'Which approach?',
                      'header': 'Approach',
                      'multiSelect': false,
                      'options': [
                        {'label': 'A', 'description': 'first'},
                        {'label': 'B'},
                      ],
                    },
                  ],
                },
              },
            ]),
          ),
          _l({'type': 'system', 'subtype': 'compact_boundary'}),
          _l({'type': 'last-prompt', 'lastPrompt': 'keep going'}),
        ]);

      expect(d.goal, 'Session summary UI');
      expect(d.lastPrompt, 'keep going');
      expect(d.steps.map((s) => [s.subject, s.state]), [
        ['Parse transcript', StepStatus.done],
        ['Build UI', StepStatus.now],
      ]);
      expect(d.files.single.edits, 2);
      expect(d.files.single.created, isTrue);
      expect(
        d.links.map((l) => l.kind),
        containsAll([LinkKind.pr, LinkKind.local]),
      );
      expect(
        d.links.firstWhere((l) => l.kind == LinkKind.local).localPort,
        5173,
      );
      expect(d.pendingAsk?.options.map((o) => o.label), ['A', 'B']);
      expect(d.taskMentions, contains('243'));
      expect(d.contextTokens, 121002);
      expect(d.compactions, 1);
      expect(modelLabel(d.model), 'Opus 5.5');
      expect(d.activity, 'Editing plan.md');
      d.addLines([
        _l(
          _asst([
            {
              'type': 'tool_use',
              'id': 'u3',
              'name': 'TaskUpdate',
              'input': {'taskId': '2', 'status': 'in_progress'},
            },
          ]),
        ),
      ]);
      expect(
        d.activity,
        isNull,
        reason: 'a step that just started has no stale activity',
      );

      d.addLines([_l(_result('q1', 'User answered'))]);
      expect(d.pendingAsk, isNull);
    });

    test('TodoWrite replaces the list', () {
      final d = Digest()
        ..addLines([
          _l(
            _asst([
              {
                'type': 'tool_use',
                'id': 't',
                'name': 'TodoWrite',
                'input': {
                  'todos': [
                    {'content': 'one', 'status': 'completed'},
                    {
                      'content': 'two',
                      'status': 'in_progress',
                      'activeForm': 'Doing two',
                    },
                  ],
                },
              },
            ]),
          ),
        ]);
      expect(d.steps.map((s) => s.state), [StepStatus.done, StepStatus.now]);
      expect(d.steps.last.activeForm, 'Doing two');
    });
  });

  group('screen prompt', () {
    const question = '''
☐ Dataset

Which evaluation dataset should we use?

❯ 1. LM-O
     Occlusion benchmark.
  2. YCB-V
     Household objects.
  3. T-LESS
     Texture-less objects.
  4. Type something.
────────────────────────────
  5. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
''';

    test('AskUserQuestion menu', () {
      final p = parsePrompt(question)!;
      expect(p.kind, PromptKind.question);
      expect(p.title, 'Dataset');
      expect(p.question, 'Which evaluation dataset should we use?');
      expect(p.options.map((o) => o.label), ['LM-O', 'YCB-V', 'T-LESS']);
      expect(p.options.first.description, 'Occlusion benchmark.');
      expect(p.customIndex, 3);
      expect(p.answer(2).single.keys, ['down', 'down', 'enter']);
      expect(p.answerText('other').map((s) => '$s'), [
        'keys:down,down,down',
        'text:other',
        'keys:enter',
      ]);
      expect(parsePrompt(question)!.id, p.id);
    });

    test('Bash approval under a tool call', () {
      final p = parsePrompt('''
● Deleting the junk directory
  ⎿  \$ rm -rf junk
────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
   rm -rf junk
   Delete the junk directory
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to
   /tmp/prompt-lab/junk from this project
   3. No
 Esc to cancel · Tab to amend
''')!;
      expect(p.kind, PromptKind.approval);
      expect(p.title, 'Bash command');
      expect(p.body, 'rm -rf junk\nDelete the junk directory');
      expect(p.options.map((o) => o.label), [
        'Yes',
        'Yes, and always allow access to /tmp/prompt-lab/junk from this project',
        'No',
      ]);
      expect(p.answer(2).single.keys, ['down', 'down', 'enter']);
    });

    test('approval with no rule still finds its title', () {
      final p = parsePrompt('''
Bash command

  curl -I https://example.com
  Fetch HTTP headers.

This command requires approval

Do you want to proceed?
❯ 1. Yes
  2. Yes, and don’t ask again for: curl *
  3. No

Esc to cancel · Tab to amend · ctrl+e to explain
''')!;
      expect(p.title, 'Bash command');
      expect(p.options.length, 3);
    });

    test('a plain screen is not a prompt unless blocked', () {
      const s = '● Done.\n\n> ';
      expect(parsePrompt(s), isNull);
      final f = parsePrompt('Overwrite? (y/n)', blocked: true)!;
      expect(f.kind, PromptKind.fallback);
      expect(f.fallbackAnswer(0).single.text, 'y');
    });

    group('live Claude Code 2.1 screens', () {
      String fx(String n) =>
          File('test/fixtures/prompts/$n').readAsStringSync();

      test('folder trust confirm', () {
        final p = parsePrompt(fx('claude_trust.txt'))!;
        expect(p.kind, PromptKind.menu);
        expect(p.question, 'Accessing workspace: /tmp/hpt');
        expect(p.options.map((o) => o.label), [
          'No, exit',
          'Yes, I trust this folder',
        ]);
        expect(p.answer(1).single.keys, ['down', 'enter']);
      });

      test('AskUserQuestion with descriptions', () {
        final p = parsePrompt(fx('claude_question.txt'))!;
        expect(p.kind, PromptKind.question);
        expect(p.title, 'Color');
        expect(p.question, 'Which color do you prefer?');
        expect(p.options.map((o) => o.label), ['Red', 'Blue']);
        expect(p.customIndex, 2);
        expect(p.answerText('green').map((s) => '$s'), [
          'keys:down,down',
          'text:green',
          'keys:enter',
        ]);
      });

      test('Write permission', () {
        final p = parsePrompt(fx('claude_write.txt'))!;
        expect(p.kind, PromptKind.approval);
        expect(p.title, 'Create file');
        expect(p.question, 'Do you want to create hello.txt?');
        expect(p.options.length, 3);
        expect(p.answer(0).single.keys, ['enter']);
      });
    });
  });

  test('status line model with and without ctx', () {
    expect(
      SessionController.statusModel(
        '  tmp/hpt master [Haiku 4.5]\n  ⏸ manual mode on',
      ),
      'Haiku 4.5',
    );
    expect(
      SessionController.statusModel(
        '  herd main [Opus 5.5 · Personal] ctx:29%\n  auto mode',
      ),
      'Opus 5.5 · Personal',
    );
    expect(SessionController.statusModel('see [link] in the docs'), isNull);
  });

  test('chat lines and the final reply of a turn', () {
    final d = Digest()
      ..addLines([
        _l({
          'type': 'user',
          'message': {'content': 'fix the login bug'},
        }),
        _l(
          _asst([
            {'type': 'text', 'text': 'Looking at it.'},
            {
              'type': 'tool_use',
              'id': 'e',
              'name': 'Edit',
              'input': {'file_path': '/r/src/auth.ts'},
            },
            {
              'type': 'tool_use',
              'id': 'b',
              'name': 'Bash',
              'input': {'command': 'npm test'},
            },
          ]),
        ),
        _l(
          _asst([
            {
              'type': 'text',
              'text': 'Fixed: the token was compared before trimming.',
            },
          ]),
        ),
      ]);
    expect(d.chat.map((c) => '${c.role.name}:${c.text}'), [
      'you:fix the login bug',
      'claude:Looking at it.',
      'tool:Edited auth.ts',
      'tool:Ran npm test',
      'claude:Fixed: the token was compared before trimming.',
    ]);
    expect(d.lastReply, 'Fixed: the token was compared before trimming.');
    d.addLines([
      _l({
        'type': 'user',
        'message': {'content': 'thanks, now deploy'},
      }),
    ]);
    expect(d.lastReply, isNull, reason: 'a new prompt starts a new turn');
  });

  test('sessions without TaskCreate get your asks as steps', () {
    final d = Digest()
      ..addLines([
        _l({
          'type': 'user',
          'message': {'content': 'add a login page'},
        }),
        _l({
          'type': 'user',
          'message': {'content': '/compact'},
        }),
        _l({
          'type': 'user',
          'message': {'content': 'now write the tests\nfor all of it'},
        }),
      ]);
    expect(d.steps, isEmpty);
    final working = d.turns(working: true);
    expect(working.map((s) => '${s.subject}:${s.state.name}'), [
      'add a login page:done',
      'now write the tests:now',
    ]);
    expect(d.turns(working: false).last.state, StepStatus.done);
  });
}
