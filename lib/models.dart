import 'dart:convert';

enum AuthMethod { key, password }

/// Same port on both ends — you type 3000 and reach the host's 3000. That is
/// what port forwarding is for in practice, and a second number to fill in
/// only invites getting it wrong.
class ForwardRule {
  final String id;
  int port;
  bool autoStart;

  ForwardRule({required this.id, required this.port, this.autoStart = false});

  String get url => 'http://localhost:$port';

  Map<String, dynamic> toJson() =>
      {'id': id, 'port': port, 'autoStart': autoStart};

  static ForwardRule fromJson(Map<String, dynamic> j) => ForwardRule(
        id: j['id'] as String,
        // Rules saved before the two-port form was collapsed.
        port: (j['port'] ?? j['localPort'] ?? j['remotePort']) as int,
        autoStart: j['autoStart'] as bool? ?? false,
      );
}

class Profile {
  final String id;
  String name;
  String host;
  int port;
  String username;
  AuthMethod auth;
  String herdrPath;
  int pollMs;
  double fontSize;
  int scrollbackLines;
  String? sessionName;
  List<ForwardRule> forwards;

  Profile({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.auth = AuthMethod.key,
    this.herdrPath = 'herdr',
    this.pollMs = 2000,
    this.fontSize = 12,
    this.scrollbackLines = 5000,
    this.sessionName,
    List<ForwardRule>? forwards,
  }) : forwards = forwards ?? [];

  String get target => '$username@$host${port == 22 ? '' : ':$port'}';

  String get secretKey => 'profile.$id.secret';
  String get passphraseKey => 'profile.$id.passphrase';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'auth': auth.name,
        'herdrPath': herdrPath,
        'pollMs': pollMs,
        'fontSize': fontSize,
        'scrollbackLines': scrollbackLines,
        'sessionName': sessionName,
        'forwards': forwards.map((f) => f.toJson()).toList(),
      };

  static Profile fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String,
        name: j['name'] as String,
        host: j['host'] as String,
        port: j['port'] as int? ?? 22,
        username: j['username'] as String,
        auth: AuthMethod.values.firstWhere(
          (a) => a.name == j['auth'],
          orElse: () => AuthMethod.key,
        ),
        herdrPath: j['herdrPath'] as String? ?? 'herdr',
        pollMs: j['pollMs'] as int? ?? 2000,
        fontSize: (j['fontSize'] as num?)?.toDouble() ?? 12,
        scrollbackLines: j['scrollbackLines'] as int? ?? 5000,
        sessionName: j['sessionName'] as String?,
        forwards: ((j['forwards'] as List?) ?? [])
            .map((f) => ForwardRule.fromJson(f as Map<String, dynamic>))
            .toList(),
      );

  Profile copy() => Profile.fromJson(jsonDecode(jsonEncode(toJson())));
}

enum AgentStatus { blocked, working, idle, done, unknown }

AgentStatus parseStatus(String? s) {
  switch (s) {
    case 'blocked':
      return AgentStatus.blocked;
    case 'working':
      return AgentStatus.working;
    case 'idle':
      return AgentStatus.idle;
    case 'done':
      return AgentStatus.done;
    default:
      return AgentStatus.unknown;
  }
}

class AgentInfo {
  final String agent;
  final AgentStatus status;
  final String cwd;
  final String foregroundCwd;
  final String paneId;
  final String tabId;
  final String workspaceId;
  final String title;
  final bool focused;
  final int revision;
  final int stateChangeSeq;

  const AgentInfo({
    required this.agent,
    required this.status,
    required this.cwd,
    required this.foregroundCwd,
    required this.paneId,
    required this.tabId,
    required this.workspaceId,
    required this.title,
    required this.focused,
    required this.revision,
    required this.stateChangeSeq,
  });

  /// Target accepted by `herdr agent <cmd> <target>`: pane ids always resolve,
  /// agent names only while unique and live.
  String get target => paneId;

  String get repo {
    final path = foregroundCwd.isNotEmpty ? foregroundCwd : cwd;
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  static AgentInfo fromJson(Map<String, dynamic> j) => AgentInfo(
        agent: j['agent'] as String? ?? 'agent',
        status: parseStatus(j['agent_status'] as String?),
        cwd: j['cwd'] as String? ?? '',
        foregroundCwd: j['foreground_cwd'] as String? ?? '',
        paneId: j['pane_id'] as String? ?? '',
        tabId: j['tab_id'] as String? ?? '',
        workspaceId: j['workspace_id'] as String? ?? '',
        title: (j['terminal_title_stripped'] as String?)?.trim().isNotEmpty ==
                true
            ? (j['terminal_title_stripped'] as String).trim()
            : (j['terminal_title'] as String? ?? '').trim(),
        focused: j['focused'] as bool? ?? false,
        revision: j['revision'] as int? ?? 0,
        stateChangeSeq: j['state_change_seq'] as int? ?? 0,
      );
}

/// Blocked agents first — they are the only ones costing the user time.
int agentSortKey(AgentInfo a) {
  switch (a.status) {
    case AgentStatus.blocked:
      return 0;
    case AgentStatus.done:
      return 1;
    case AgentStatus.working:
      return 2;
    case AgentStatus.idle:
      return 3;
    case AgentStatus.unknown:
      return 4;
  }
}

/// A row of herdr's sidebar, which the phone renders as a real screen instead.
class WorkspaceInfo {
  final String id;
  final String label;
  final int number;
  final AgentStatus status;
  final bool focused;
  final int tabCount;
  final int paneCount;

  const WorkspaceInfo({
    required this.id,
    required this.label,
    required this.number,
    required this.status,
    required this.focused,
    required this.tabCount,
    required this.paneCount,
  });

  static WorkspaceInfo fromJson(Map<String, dynamic> j) => WorkspaceInfo(
        id: j['workspace_id'] as String? ?? '',
        label: (j['label'] as String?)?.trim().isNotEmpty == true
            ? (j['label'] as String).trim()
            : (j['workspace_id'] as String? ?? 'workspace'),
        number: j['number'] as int? ?? 0,
        status: parseStatus(j['agent_status'] as String?),
        focused: j['focused'] as bool? ?? false,
        tabCount: j['tab_count'] as int? ?? 0,
        paneCount: j['pane_count'] as int? ?? 0,
      );
}

/// A tab inside a workspace. Listed whether or not an agent is running in it —
/// `agent_status` is simply `unknown` for a plain shell.
class TabInfo {
  final String id;
  final String workspaceId;
  final String label;
  final int number;
  final AgentStatus status;
  final bool focused;
  final int paneCount;

  /// First pane in this tab, so it can be opened even with no agent present.
  final String? paneId;

  const TabInfo({
    required this.id,
    required this.workspaceId,
    required this.label,
    required this.number,
    required this.status,
    required this.focused,
    required this.paneCount,
    this.paneId,
  });

  bool get hasAgent => status != AgentStatus.unknown;

  TabInfo withPane(String? p) => TabInfo(
        id: id,
        workspaceId: workspaceId,
        label: label,
        number: number,
        status: status,
        focused: focused,
        paneCount: paneCount,
        paneId: p,
      );

  static TabInfo fromJson(Map<String, dynamic> j) => TabInfo(
        id: j['tab_id'] as String? ?? '',
        workspaceId: j['workspace_id'] as String? ?? '',
        label: (j['label'] as String?)?.trim().isNotEmpty == true
            ? (j['label'] as String).trim()
            : '${j['number'] ?? ''}',
        number: j['number'] as int? ?? 0,
        status: parseStatus(j['agent_status'] as String?),
        focused: j['focused'] as bool? ?? false,
        paneCount: j['pane_count'] as int? ?? 0,
      );
}

class SessionInfo {
  final String name;
  final bool running;
  final bool isDefault;

  const SessionInfo({
    required this.name,
    required this.running,
    required this.isDefault,
  });

  static SessionInfo fromJson(Map<String, dynamic> j) => SessionInfo(
        name: j['name'] as String? ?? 'default',
        running: j['running'] as bool? ?? false,
        isDefault: j['default'] as bool? ?? false,
      );
}

class KnownHost {
  final String hostPort;
  final String fingerprint;

  const KnownHost(this.hostPort, this.fingerprint);
}
