import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/app_state.dart';
import 'package:herdr_mobile/herdr.dart';
import 'package:herdr_mobile/models.dart';
import 'package:herdr_mobile/screens/session/peek_screen.dart';
import 'package:herdr_mobile/screens/session/session_screen.dart';
import 'package:herdr_mobile/session/controller.dart';
import 'package:herdr_mobile/session/prompt.dart';
import 'package:herdr_mobile/store.dart';
import 'package:herdr_mobile/theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pane = 'w1:p1';

Future<SessionController> _session(
  WidgetTester tester, {
  AgentStatus status = AgentStatus.idle,
  ScreenPrompt? prompt,
}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final app = AppState(await Store.open());
  app.agents = [
    AgentInfo(
      agent: 'claude',
      status: status,
      cwd: '/home/v/Projects/herd',
      foregroundCwd: '/home/v/Projects/herd',
      paneId: _pane,
      tabId: 'w1:t1',
      workspaceId: 'w1',
      title: 'Session summary UI',
      focused: false,
      revision: 1,
      stateChangeSeq: 1,
    ),
  ];
  final c = SessionController(app, _pane);
  c.digest.addLines([
    jsonEncode({'type': 'ai-title', 'aiTitle': 'Session summary UI'}),
    jsonEncode({
      'type': 'user',
      'message': {'content': 'build the summary screen'},
    }),
    jsonEncode({
      'type': 'assistant',
      'message': {
        'model': 'claude-opus-5-5',
        'usage': {'input_tokens': 1, 'cache_read_input_tokens': 124000},
        'content': [
          {
            'type': 'tool_use',
            'id': 't',
            'name': 'TodoWrite',
            'input': {
              'todos': [
                {'content': 'Map pane to transcript', 'status': 'completed'},
                {
                  'content': 'Build the summary screen',
                  'status': 'in_progress',
                },
                {'content': 'Ship it', 'status': 'pending'},
              ],
            },
          },
          {
            'type': 'tool_use',
            'id': 'w',
            'name': 'Write',
            'input': {'file_path': '/home/v/Projects/herd/docs/plan.md'},
          },
          {'type': 'text', 'text': 'PR: https://github.com/v/herd/pull/41'},
        ],
      },
    }),
  ]);
  c.loaded = true;
  c.prompt = prompt;
  await tester.binding.setSurfaceSize(const Size(400, 860));
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: SessionScreen(paneId: _pane, controller: c),
      ),
    ),
  );
  await tester.pump();
  return c;
}

void main() {
  testWidgets('summary shows the goal, steps and composer', (tester) async {
    await _session(tester);
    expect(find.text('Session summary UI'), findsWidgets);
    expect(find.text('Build the summary screen'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.text('WORKING TOWARDS'), findsOneWidget);
    expect(find.text('62%'), findsOneWidget);
    expect(find.textContaining('@ files'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);
  });

  testWidgets('a question on screen replaces the composer', (tester) async {
    await _session(
      tester,
      status: AgentStatus.blocked,
      prompt: ScreenPrompt(
        kind: PromptKind.question,
        title: 'Approach',
        question: 'Which approach?',
        options: const [
          PromptOption('Embed in WebView (Recommended)', 'Forward :7317'),
          PromptOption('Native Flutter rewrite'),
        ],
        customIndex: 2,
      ),
    );
    expect(find.text('Which approach?'), findsOneWidget);
    expect(find.text('Embed in WebView'), findsOneWidget);
    expect(find.text('REC'), findsOneWidget);
    expect(find.text('Other — type an answer'), findsOneWidget);
    expect(find.textContaining('@ files'), findsNothing);
  });

  testWidgets('a permission prompt shows its command', (tester) async {
    await _session(
      tester,
      status: AgentStatus.blocked,
      prompt: ScreenPrompt(
        kind: PromptKind.approval,
        title: 'Bash command',
        question: 'Do you want to proceed?',
        body: 'rm -rf junk',
        options: const [PromptOption('Yes'), PromptOption('No')],
      ),
    );
    expect(find.text('NEEDS YOU · PERMISSION'), findsOneWidget);
    expect(find.text('rm -rf junk'), findsOneWidget);
    expect(find.text('No'), findsOneWidget);
  });

  testWidgets('refs lists links and written files', (tester) async {
    await _session(tester);
    await tester.tap(find.byIcon(Icons.link_rounded));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('PR #41'), findsOneWidget);
    expect(find.text('plan.md'), findsOneWidget);
  });

  testWidgets('model pill opens the preset slider and the host model list', (
    tester,
  ) async {
    final c = await _session(tester);
    c.catalog = const ClaudeModels(
      [
        ModelOption(
          'claude-opus-5-5[1m]',
          'Opus 5.5',
          'Shared pool',
          'claude-opus-5-5',
        ),
        ModelOption(
          'seis-claude-opus-5-5[1m]',
          'Opus 5.5 · Personal',
          'Pinned',
          'claude-opus-5-5',
        ),
        ModelOption(
          'claude-fable-5-1[1m]',
          'Fable 5.1',
          'Shared pool',
          'claude-fable-5-1',
        ),
      ],
      {'claude-opus-5-5': 'high'},
      null,
    );
    c.currentLabel = 'Opus 5.5';
    await c.setEffort('high');
    await tester.pump();
    expect(find.textContaining('Deep'), findsOneWidget);
    await tester.tap(find.textContaining('Deep'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Opus 5.5 · high effort'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right_rounded).last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.text('Opus 5.5 · Personal'), findsOneWidget);
    expect(find.text('Fable 5.1'), findsOneWidget);
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Opus 5.5'),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the context ring drops the context panel', (tester) async {
    await _session(tester);
    await tester.tap(find.text('62%'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Compact'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('124k of 200k'), findsOneWidget);
  });

  testWidgets('a working agent queues instead of sending', (tester) async {
    final c = await _session(tester, status: AgentStatus.working);
    await tester.enterText(find.byType(TextField), 'also run the tests');
    await tester.tap(find.byIcon(Icons.schedule_send_rounded));
    await tester.pump();
    expect(c.queue, ['also run the tests']);
    expect(find.text('also run the tests'), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
  });

  testWidgets('the result shows once the turn is over, not while working', (
    tester,
  ) async {
    final c = await _session(tester, status: AgentStatus.idle);
    c.digest.addLines([
      jsonEncode({
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'text', 'text': 'All three screens are done.'},
          ],
        },
      }),
    ]);
    c.notifyListeners();
    await tester.pump();
    expect(find.text('RESULT'), findsOneWidget);
    expect(find.text('All three screens are done.'), findsOneWidget);

    c.app.agents = [
      for (final a in c.app.agents)
        AgentInfo(
          agent: a.agent,
          status: AgentStatus.working,
          cwd: a.cwd,
          foregroundCwd: a.foregroundCwd,
          paneId: a.paneId,
          tabId: a.tabId,
          workspaceId: a.workspaceId,
          title: a.title,
          focused: false,
          revision: 2,
          stateChangeSeq: 2,
        ),
    ];
    c.notifyListeners();
    await tester.pump();
    expect(find.text('RESULT'), findsNothing);
  });

  testWidgets('peek shows an agent conversation', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final app = AppState(await Store.open());
    app.agents = [
      AgentInfo(
        agent: 'claude',
        status: AgentStatus.idle,
        cwd: '/p/herd',
        foregroundCwd: '/p/herd',
        paneId: 'w1:p1',
        tabId: 't',
        workspaceId: 'w1',
        title: 'Herd UI',
        focused: false,
        revision: 1,
        stateChangeSeq: 1,
      ),
      AgentInfo(
        agent: 'codex',
        status: AgentStatus.working,
        cwd: '/p/api',
        foregroundCwd: '/p/api',
        paneId: 'w2:p1',
        tabId: 't',
        workspaceId: 'w2',
        title: 'API',
        focused: false,
        revision: 1,
        stateChangeSeq: 1,
      ),
    ];
    await tester.binding.setSurfaceSize(const Size(400, 860));
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: const PeekScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Peek'), findsOneWidget);
    expect(find.text('herd'), findsOneWidget);
    expect(find.text('api'), findsOneWidget);
  });

  testWidgets('summary page switches to the full chat', (tester) async {
    await _session(tester);
    expect(find.text('Build the summary screen'), findsOneWidget);
    await tester.tap(find.text('Chat'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('build the summary screen'), findsOneWidget);
    expect(find.text('Wrote plan.md'), findsOneWidget);
    expect(find.text('WORKING TOWARDS'), findsNothing);
    expect(find.textContaining('@ files'), findsOneWidget);
  });

  testWidgets('summary lists the session agents', (tester) async {
    final c = await _session(tester);
    c.subAgents = const [
      SubAgent(
        '/x/agent-a.jsonl',
        'Spec upstream chat parsing',
        'general-purpose',
        10,
      ),
      SubAgent('/x/agent-b.jsonl', 'Review the diff', 'fork', 7200),
    ];
    c.notifyListeners();
    await tester.pump();
    expect(find.text('AGENTS'), findsOneWidget);
    expect(find.text('1 running'), findsOneWidget);
    expect(find.text('Spec upstream chat parsing'), findsOneWidget);
    expect(find.text('fork · finished 2h ago'), findsNothing);
    await tester.ensureVisible(find.text('Show 1 earlier'));
    await tester.pump();
    await tester.tap(find.text('Show 1 earlier'));
    await tester.pump();
    expect(
      find.text('fork · finished 2h ago', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('changing effort asks first, since it becomes a default', (
    tester,
  ) async {
    final c = await _session(tester);
    c.currentLabel = 'Opus 5.5';
    await c.setEffort('high');
    await tester.pump();
    await tester.tap(find.textContaining('Deep'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byIcon(Icons.chevron_right_rounded).last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('low'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Set effort to low?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.effort, 'high');
  });
}
