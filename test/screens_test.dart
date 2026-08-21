import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/app_state.dart';
import 'package:herdr_mobile/herdr.dart';
import 'package:herdr_mobile/models.dart';
import 'package:herdr_mobile/screens/agents_screen.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:herdr_mobile/screens/files_screen.dart';
import 'package:herdr_mobile/screens/forwards_screen.dart';
import 'package:herdr_mobile/screens/profile_edit_screen.dart';
import 'package:herdr_mobile/screens/profiles_screen.dart';
import 'package:herdr_mobile/screens/settings_screen.dart';
import 'package:herdr_mobile/screens/terminal_screen.dart';
import 'package:herdr_mobile/store.dart';
import 'package:herdr_mobile/theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Renders every screen headlessly. This is the cheap stand-in for launching
/// on a device: it catches layout overflow, null derefs in build(), and
/// missing providers, which is most of what a first run would surface.
Future<AppState> _state() async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  return AppState(await Store.open());
}

Widget _wrap(AppState app, Widget child) => ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: child,
      ),
    );

AgentInfo _agent(
  String name,
  AgentStatus status, {
  String workspace = 'w1',
  String pane = 'w1:p1',
  String title = 'Wire up the telemetry feed',
}) =>
    AgentInfo(
      agent: name,
      status: status,
      cwd: '/home/v/Projects/Strix',
      foregroundCwd: '/home/v/Projects/Strix',
      paneId: pane,
      tabId: '$workspace:t1',
      workspaceId: workspace,
      title: title,
      focused: false,
      revision: 1,
      stateChangeSeq: 1,
    );

void main() {
  testWidgets('profiles screen shows the empty state first', (tester) async {
    final app = await _state();
    await tester.pumpWidget(_wrap(app, const ProfilesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Herd'), findsOneWidget);
    expect(find.text('No hosts yet'), findsOneWidget);
    // The one prerequisite must be stated, not assumed.
    expect(find.textContaining('herdr on its PATH'), findsOneWidget);
  });

  testWidgets('profiles screen lists a saved host', (tester) async {
    final app = await _state();
    await app.saveProfile(Profile(
      id: '1',
      name: 'hetzner-01',
      host: '10.0.0.5',
      username: 'v',
    ));
    await tester.pumpWidget(_wrap(app, const ProfilesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('hetzner-01'), findsOneWidget);
    expect(find.text('v@10.0.0.5'), findsOneWidget);
  });

  testWidgets('profile editor validates before saving', (tester) async {
    final app = await _state();
    await tester.pumpWidget(_wrap(app, const ProfileEditScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Give it a name'), findsOneWidget);
    expect(find.text('Required'), findsWidgets);
    expect(app.profiles, isEmpty);
  });

  testWidgets('profile editor rejects an out-of-range port', (tester) async {
    final app = await _state();
    await tester.pumpWidget(_wrap(app, const ProfileEditScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(2), '99999');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('1-65535'), findsOneWidget);
  });

  testWidgets('agents screen sorts blocked first and filters', (tester) async {
    final app = await _state();
    app.active = Profile(id: '1', name: 'box', host: 'h', username: 'v')
      ..sessionName = 'default';
    app.state = ConnState.connected;
    app.agents = [
      _agent('blocked-one', AgentStatus.blocked,
          pane: 'w1:p1', title: 'Fix the migration'),
      _agent('working-one', AgentStatus.working,
          pane: 'w1:p2', title: 'Rename the columns'),
      _agent('idle-one', AgentStatus.idle,
          pane: 'w1:p3', title: 'Wire up telemetry'),
    ];

    await tester.pumpWidget(_wrap(app, const AgentsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Fix the migration'), findsOneWidget);
    expect(find.text('All 3'), findsOneWidget);

    // The blocked card renders above the others.
    final blockedY = tester.getTopLeft(find.text('Fix the migration')).dy;
    final idleY = tester.getTopLeft(find.text('Wire up telemetry')).dy;
    expect(blockedY, lessThan(idleY));

    await tester.tap(find.text('blocked 1'));
    await tester.pumpAndSettle();
    expect(find.text('Fix the migration'), findsOneWidget);
    expect(find.text('Wire up telemetry'), findsNothing);
  });

  // The task is what you read at arm's length; the model that runs it is a
  // detail, and a titleless agent must still be identifiable.
  testWidgets('an agent card leads with its task, not its model',
      (tester) async {
    final app = await _state();
    app.active = Profile(id: '1', name: 'box', host: 'h', username: 'v');
    app.state = ConnState.connected;
    app.agents = [
      _agent('claude', AgentStatus.working,
          pane: 'w1:p1', title: 'Revert the migrations'),
      _agent('codex', AgentStatus.idle, pane: 'w1:p2', title: ''),
    ];

    await tester.pumpWidget(_wrap(app, const AgentsScreen()));
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(find.text('Revert the migrations'));
    expect(title.style?.fontSize, 15);
    expect(find.text('claude · Strix · w1:p1'), findsOneWidget);

    // No title to lead with, so the agent's name takes the headline.
    expect(find.text('codex'), findsOneWidget);
  });

  testWidgets('agents screen groups by workspace when there are several',
      (tester) async {
    final app = await _state();
    app.active = Profile(id: '1', name: 'box', host: 'h', username: 'v');
    app.state = ConnState.connected;
    app.agents = [
      _agent('one', AgentStatus.idle, workspace: 'w1', pane: 'w1:p1'),
      _agent('two', AgentStatus.idle, workspace: 'w3', pane: 'w3:p1'),
    ];

    await tester.pumpWidget(_wrap(app, const AgentsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('workspace w1 · 1'), findsOneWidget);
    expect(find.text('workspace w3 · 1'), findsOneWidget);
  });

  testWidgets('ports is a top-bar button, not buried in the menu',
      (tester) async {
    final app = await _state();
    app.active = Profile(id: '1', name: 'box', host: 'h', username: 'v');
    app.state = ConnState.connected;
    app.agents = [_agent('claude', AgentStatus.idle)];

    await tester.pumpWidget(_wrap(app, const AgentsScreen()));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.swap_horiz), findsOneWidget);

    await tester.tap(find.byIcon(Icons.swap_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Ports'), findsOneWidget);
  });

  testWidgets('agents screen shows an empty session honestly', (tester) async {
    final app = await _state();
    app.active = Profile(id: '1', name: 'box', host: 'h', username: 'v');
    app.state = ConnState.connected;
    app.agents = [];

    await tester.pumpWidget(_wrap(app, const AgentsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('No agents running in this session.'), findsOneWidget);
  });

  testWidgets('a failed connection offers a retry, not a blank list',
      (tester) async {
    final app = await _state();
    app.active = Profile(id: '1', name: 'box', host: 'h', username: 'v');
    app.state = ConnState.failed;
    app.error = 'Authentication failed: bad key';

    await tester.pumpWidget(_wrap(app, const AgentsScreen()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Authentication failed'), findsOneWidget);
    expect(find.text('Retry now'), findsOneWidget);
  });

  testWidgets('forwards screen explains itself when empty', (tester) async {
    final app = await _state();
    final p = Profile(id: '1', name: 'box', host: 'h', username: 'v');
    await tester.pumpWidget(_wrap(app, ForwardsScreen(profile: p)));
    await tester.pumpAndSettle();

    expect(find.textContaining('server running on the host'), findsOneWidget);
  });

  testWidgets('forwards screen renders a rule', (tester) async {
    final app = await _state();
    final p = Profile(id: '1', name: 'box', host: 'h', username: 'v')
      ..forwards.add(
        ForwardRule(id: 'f', port: 3000),
      );
    await tester.pumpWidget(_wrap(app, ForwardsScreen(profile: p)));
    await tester.pumpAndSettle();

    expect(find.text('3000'), findsOneWidget);
    expect(find.text('localhost:3000'), findsOneWidget);
  });

  testWidgets('settings screen renders and lists pinned hosts',
      (tester) async {
    final app = await _state();
    app.knownHosts['10.0.0.5:22'] = 'AAAAfingerprintBBBB';

    await tester.pumpWidget(_wrap(app, const SettingsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('10.0.0.5:22'), findsOneWidget);
    expect(find.text('Clear uploaded images'), findsOneWidget);
  });

  testWidgets('terminal screen renders its chrome without a connection',
      (tester) async {
    final app = await _state();
    app.active = Profile(id: '1', name: 'box', host: 'h', username: 'v');
    app.state = ConnState.connected;
    app.agents = [_agent('claude', AgentStatus.working, pane: 'w1:p1')];

    await tester.pumpWidget(_wrap(app, const TerminalScreen(target: 'w1:p1')));
    await tester.pump();

    expect(find.text('claude'), findsWidgets);
    expect(find.text('Message the agent…'), findsOneWidget);
    // herdr's spellings, not the obvious guesses.
    expect(find.text('pgUp'), findsOneWidget);
    expect(find.text('ESC'), findsOneWidget);
    expect(find.text('CTRL'), findsOneWidget);
  });

  testWidgets('a blocked agent gets a banner pointing at the prompt',
      (tester) async {
    final app = await _state();
    app.active = Profile(id: '1', name: 'box', host: 'h', username: 'v');
    app.state = ConnState.connected;
    app.agents = [_agent('claude', AgentStatus.blocked, pane: 'w1:p1')];

    await tester.pumpWidget(_wrap(app, const TerminalScreen(target: 'w1:p1')));
    await tester.pump();

    expect(find.textContaining('Waiting on you'), findsOneWidget);
  });

  testWidgets('the terminal gives its rows to the pane, not to chrome',
      (tester) async {
    final app = await _state();
    app.active = Profile(id: '1', name: 'box', host: 'h', username: 'v');
    app.state = ConnState.connected;
    app.agents = [
      _agent('claude', AgentStatus.working, pane: 'w1:p1'),
      _agent('codex', AgentStatus.idle, pane: 'w1:p2'),
    ];

    await tester.pumpWidget(_wrap(app, const TerminalScreen(target: 'w1:p1')));
    await tester.pump();

    // No sibling tab strip: herdr draws its own tab header, and duplicating
    // it costs terminal rows.
    expect(find.text('codex'), findsNothing);
    // Full-screen control is present so the app bar can be dropped too.
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
  });

  testWidgets('status chips carry a word, not just a colour', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: AgentStatus.values.map(StatusChip.new).toList(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final s in AgentStatus.values) {
      expect(find.textContaining(lookFor(s).label), findsOneWidget);
    }
  });

  // A Tailscale check arrives mid-handshake and has to close itself again, or
  // it is left stranded under whatever screen the connection opens next.
  testWidgets('an auth notice shows its link and then closes', (tester) async {
    final app = await _state();
    await tester.pumpWidget(_wrap(app, const ProfilesScreen()));
    await tester.pumpAndSettle();

    app.showAuthNotice!('# To authenticate, visit: https://login.tailscale.com/a/f');
    await tester.pumpAndSettle();
    expect(find.text('One more check'), findsOneWidget);
    expect(find.text('Open link'), findsOneWidget);

    // A second banner must not stack a second dialog.
    app.showAuthNotice!('# To authenticate, visit: https://login.tailscale.com/a/f');
    await tester.pumpAndSettle();
    expect(find.text('One more check'), findsOneWidget);

    app.hideAuthNotice!();
    await tester.pumpAndSettle();
    expect(find.text('One more check'), findsNothing);
  });


  testWidgets('files screen says so when there is no connection',
      (tester) async {
    final app = await _state();
    // An agent that reports no cwd would otherwise land here with an empty path.
    await tester.pumpWidget(_wrap(app, const FilesScreen(path: '')));
    await tester.pumpAndSettle();
    expect(find.text('Not connected.'), findsOneWidget);
  });

  testWidgets('markdown renders as headings and text, not as source',
      (tester) async {
    final app = await _state();
    await tester.pumpWidget(_wrap(
      app,
      Builder(
        builder: (c) => MarkdownBody(
          data: '# Title\n\nSome **bold** text.',
          styleSheet: githubStyle(c),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Title'), findsOneWidget);
    expect(find.textContaining('#'), findsNothing);
  });
}
