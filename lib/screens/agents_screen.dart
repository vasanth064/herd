import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../herdr.dart';
import '../models.dart';
import '../theme.dart';
import 'files_screen.dart';
import 'forwards_screen.dart';
import 'settings_screen.dart';
import 'workspaces_screen.dart';
import 'terminal_screen.dart';

class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key});

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> {
  AgentStatus? _filter;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Keeps the freshness label counting up between polls.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _pickSession(AppState app) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('herdr sessions',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            ...app.sessions.map(
              (s) => ListTile(
                enabled: s.running,
                leading: Icon(
                  s.running ? Icons.circle : Icons.circle_outlined,
                  size: 12,
                  color: s.running ? const Color(0xFF4CAF50) : null,
                ),
                title: Text(s.name, style: const TextStyle(fontFamily: mono)),
                subtitle: Text(s.running ? 'running' : 'stopped'),
                trailing: app.active?.sessionName == s.name
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(c, s.name),
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen != null) await app.selectSession(chosen);
  }

  String _freshness(AppState app) {
    if (app.pollStale) return 'stale';
    final t = app.lastPoll;
    if (t == null) return '—';
    return '${DateTime.now().difference(t).inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final profile = app.active;
    final all = app.agents;
    final shown =
        _filter == null ? all : all.where((a) => a.status == _filter).toList();

    final counts = <AgentStatus, int>{};
    for (final a in all) {
      counts[a.status] = (counts[a.status] ?? 0) + 1;
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(profile?.name ?? 'Agents',
                style: const TextStyle(fontSize: 17)),
            Text(
              '${profile?.sessionName ?? 'default'} · ${_freshness(app)}',
              style: TextStyle(
                fontSize: 11,
                fontFamily: mono,
                color: app.pollStale ? const Color(0xFFFF5252) : null,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Workspaces',
            icon: const Icon(Icons.dashboard_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WorkspacesScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Files',
            icon: const Icon(Icons.folder_outlined),
            onPressed: () async {
              final c = app.conn;
              if (c == null || !c.isConnected) return;
              String home;
              try {
                home = await c.homeDir();
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('$e')));
                }
                return;
              }
              if (!context.mounted) return;
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => FilesScreen(path: home)),
              );
            },
          ),
          if (profile != null)
            _PortsButton(
              profile: profile,
              activeCount:
                  profile.forwards.where(app.forwardActive).length,
            ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'sessions':
                  await _pickSession(app);
                case 'settings':
                  if (context.mounted) {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const SettingsScreen()),
                    );
                  }
                case 'disconnect':
                  await app.disconnect();
                  if (context.mounted) Navigator.pop(context);
              }
            },
            itemBuilder: (c) => [
              PopupMenuItem(
                value: 'sessions',
                enabled: app.sessions.length > 1,
                child: Text('Session (${app.sessions.length})'),
              ),
              const PopupMenuItem(value: 'settings', child: Text('Settings')),
              const PopupMenuItem(
                  value: 'disconnect', child: Text('Disconnect')),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                _Filter(
                  label: 'All ${all.length}',
                  selected: _filter == null,
                  onTap: () => setState(() => _filter = null),
                ),
                for (final s in [
                  AgentStatus.blocked,
                  AgentStatus.working,
                  AgentStatus.idle,
                  AgentStatus.done,
                ])
                  if ((counts[s] ?? 0) > 0)
                    _Filter(
                      label: '${lookFor(s).label} ${counts[s]}',
                      color: lookFor(s).color,
                      selected: _filter == s,
                      onTap: () => setState(
                          () => _filter = _filter == s ? null : s),
                    ),
              ],
            ),
          ),
        ),
      ),
      body: app.state == ConnState.failed
          ? _Failed(app: app)
          : RefreshIndicator(
              onRefresh: app.refresh,
              child: shown.isEmpty
                  ? ListView(
                      children: [
                        const SizedBox(height: 120),
                        Center(
                          child: Text(
                            all.isEmpty
                                ? 'No agents running in this session.'
                                : 'Nothing ${_filter == null ? '' : lookFor(_filter!).label}.',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    )
                  : _AgentList(agents: shown),
            ),
    );
  }
}

/// Flat when there is one workspace; grouped under pinned headers when there
/// are several, so a long list still tells you which workspace you are reading.
class _AgentList extends StatelessWidget {
  final List<AgentInfo> agents;
  const _AgentList({required this.agents});

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<AgentInfo>>{};
    for (final a in agents) {
      groups.putIfAbsent(a.workspaceId, () => []).add(a);
    }

    Widget card(AgentInfo a) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _AgentCard(
            agent: a,
            held: context.read<AppState>().heldFor(a.paneId),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TerminalScreen(target: a.paneId),
              ),
            ),
          ),
        );

    if (groups.length <= 1) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: agents.map(card).toList(),
      );
    }

    return CustomScrollView(
      slivers: [
        for (final entry in groups.entries) ...[
          SliverPersistentHeader(
            pinned: true,
            delegate: _WorkspaceHeader(
              label: entry.key,
              count: entry.value.length,
              background: Theme.of(context).scaffoldBackgroundColor,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            sliver: SliverList.list(
              children: entry.value.map(card).toList(),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

class _WorkspaceHeader extends SliverPersistentHeaderDelegate {
  final String label;
  final int count;
  final Color background;
  final Color color;

  _WorkspaceHeader({
    required this.label,
    required this.count,
    required this.background,
    required this.color,
  });

  @override
  double get minExtent => 32;

  @override
  double get maxExtent => 32;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return Container(
      color: background,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Text(
        'workspace $label · $count',
        style: TextStyle(
          fontSize: 11,
          fontFamily: mono,
          letterSpacing: 0.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_WorkspaceHeader old) =>
      old.label != label || old.count != count || old.background != background;
}

/// Ports live in the bar, not the overflow — the count is state you want to
/// see without opening a menu.
class _PortsButton extends StatelessWidget {
  final Profile profile;
  final int activeCount;

  const _PortsButton({required this.profile, required this.activeCount});

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      tooltip: activeCount == 0
          ? 'Ports'
          : '$activeCount port${activeCount == 1 ? '' : 's'} forwarded',
      icon: const Icon(Icons.swap_horiz),
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ForwardsScreen(profile: profile, live: true),
        ),
      ),
    );
    if (activeCount == 0) return button;
    return Badge.count(
      count: activeCount,
      backgroundColor: const Color(0xFF4CAF50),
      textColor: Colors.black,
      offset: const Offset(-4, 4),
      child: button,
    );
  }
}

class _Filter extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final VoidCallback onTap;

  const _Filter({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => onTap(),
        side: color == null
            ? null
            : BorderSide(color: color!.withValues(alpha: 0.5)),
      ),
    );
  }
}

class _AgentCard extends StatelessWidget {
  final AgentInfo agent;
  final VoidCallback onTap;
  final Duration? held;

  const _AgentCard({required this.agent, required this.onTap, this.held});

  @override
  Widget build(BuildContext context) {
    final blocked = agent.status == AgentStatus.blocked;
    final look = lookFor(agent.status);
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border(
              left: BorderSide(
                color: blocked ? look.color : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(13, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: StatusDot(agent.status),
                  ),
                  const SizedBox(width: 8),
                  // What the agent is doing is the only thing worth reading at
                  // arm's length; which model it is barely matters.
                  Expanded(
                    child: Text(
                      agent.title.isNotEmpty ? agent.title : agent.agent,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      StatusChip(agent.status),
                      if (held != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          shortAge(held!),
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: mono,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${agent.agent} · ${agent.repo} · ${agent.paneId}',
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: mono,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  final AppState app;
  const _Failed({required this.app});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_off, size: 40),
            const SizedBox(height: 14),
            Text(
              app.error ?? 'Disconnected.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, fontFamily: mono),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () {
                final p = app.active;
                if (p != null) app.connect(p);
              },
              child: const Text('Retry now'),
            ),
          ],
        ),
      ),
    );
  }
}
