import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../herdr.dart';
import '../models.dart';
import '../theme.dart';
import 'agents_screen.dart';
import 'profile_edit_screen.dart';
import 'settings_screen.dart';

class ProfilesScreen extends StatefulWidget {
  const ProfilesScreen({super.key});

  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().hostKeyPrompt = _askHostKey;
    });
  }

  Future<bool> _askHostKey(String hostPort, String fingerprint) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('Unknown host'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('First connection to $hostPort.'),
            const SizedBox(height: 12),
            const Text('SHA256 fingerprint:'),
            const SizedBox(height: 4),
            SelectableText(
              fingerprint,
              style: const TextStyle(fontFamily: mono, fontSize: 12),
            ),
            const SizedBox(height: 12),
            const Text(
              'Accept only if this matches the server. It will be pinned, and '
              'any later change will be refused.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Trust'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _open(Profile p) async {
    final app = context.read<AppState>();
    await app.connect(p);
    if (!mounted) return;
    if (app.state == ConnState.connected) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AgentsScreen()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(app.error ?? 'Could not connect.')),
      );
    }
  }

  Future<void> _edit(Profile? p) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProfileEditScreen(profile: p)),
    );
  }

  Future<void> _confirmDelete(Profile p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${p.name}?'),
        content: const Text('The profile and its stored key are removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppState>().deleteProfile(p);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Herd'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('Host'),
      ),
      body: app.profiles.isEmpty
          ? const _EmptyProfiles()
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: app.profiles.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final p = app.profiles[i];
                final isActive = app.active?.id == p.id;
                return Card(
                  child: ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    leading: _ConnDot(
                      isActive ? app.state : ConnState.disconnected,
                    ),
                    title: Text(p.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      p.target,
                      style: const TextStyle(fontFamily: mono, fontSize: 12),
                    ),
                    trailing: isActive && app.state == ConnState.connected
                        ? _CountBadge(app.agents)
                        : const Icon(Icons.chevron_right),
                    onTap: () => _open(p),
                    onLongPress: () => showModalBottomSheet(
                      context: context,
                      builder: (c) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.edit_outlined),
                              title: const Text('Edit'),
                              onTap: () {
                                Navigator.pop(c);
                                _edit(p);
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.copy_all_outlined),
                              title: const Text('Duplicate'),
                              onTap: () {
                                Navigator.pop(c);
                                final d = p.copy();
                                context.read<AppState>().saveProfile(
                                      Profile.fromJson({
                                        ...d.toJson(),
                                        'id': DateTime.now()
                                            .microsecondsSinceEpoch
                                            .toString(),
                                        'name': '${p.name} copy',
                                      }),
                                    );
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.delete_outline),
                              title: const Text('Delete'),
                              onTap: () {
                                Navigator.pop(c);
                                _confirmDelete(p);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _ConnDot extends StatelessWidget {
  final ConnState state;
  const _ConnDot(this.state);

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      ConnState.connected => (const Color(0xFF4CAF50), 'connected'),
      ConnState.connecting => (const Color(0xFFFFC107), 'connecting'),
      ConnState.failed => (const Color(0xFFFF5252), 'failed'),
      ConnState.disconnected => (const Color(0xFF616161), 'disconnected'),
    };
    return Semantics(
      label: label,
      child: SizedBox(
        width: 24,
        height: 24,
        child: Center(
          child: state == ConnState.connecting
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: color),
                )
              : Container(
                  width: 12,
                  height: 12,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final List<AgentInfo> agents;
  const _CountBadge(this.agents);

  @override
  Widget build(BuildContext context) {
    final blocked =
        agents.where((a) => a.status == AgentStatus.blocked).length;
    final working =
        agents.where((a) => a.status == AgentStatus.working).length;
    final parts = [
      if (working > 0) '$working working',
      if (blocked > 0) '$blocked blocked',
    ];
    return Text(
      parts.isEmpty ? '${agents.length} agents' : parts.join(' · '),
      style: TextStyle(
        fontSize: 11,
        fontFamily: mono,
        color: blocked > 0 ? const Color(0xFFFF5252) : null,
      ),
    );
  }
}

class _EmptyProfiles extends StatelessWidget {
  const _EmptyProfiles();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns_outlined, size: 48),
            const SizedBox(height: 16),
            Text('No hosts yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Add the machine your agents run on. It needs herdr on its PATH '
              'and SSH reachable — nothing else to install.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
