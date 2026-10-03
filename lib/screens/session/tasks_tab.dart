import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../session/controller.dart';
import '../../theme.dart';
import 'widgets.dart';

/// The current project's tsk board, and nothing else.
class TasksTab extends StatefulWidget {
  const TasksTab({super.key});
  @override
  State<TasksTab> createState() => _TasksTabState();
}

class _TasksTabState extends State<TasksTab> {
  String filter = 'Open';
  String? root;
  List<Map<String, dynamic>> open = [];
  List<Map<String, dynamic>> done = [];
  bool loading = true;
  String? error;

  static const _statuses = ['open', 'started', 'review', 'done'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final conn = context.read<AppState>().conn;
    final a = context.read<SessionController>().agent;
    if (conn == null || a == null) return;
    try {
      root ??= await conn.projectRoot(
        a.foregroundCwd.isNotEmpty ? a.foregroundCwd : a.cwd,
      );
      final o = await conn.tskList(root!);
      final d = await conn.tskList(root!, done: true);
      if (mounted) {
        setState(() {
          open = o;
          done = d;
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$e';
        });
      }
    }
  }

  List<Map<String, dynamic>> _shown(Set<String> mentions) => switch (filter) {
    'Review' => open.where((t) => t['status'] == 'review').toList(),
    'Done' => done,
    'This session' => [
      ...open,
      ...done,
    ].where((t) => mentions.contains('${t['number']}')).toList(),
    _ => open.where((t) => t['status'] != 'review').toList(),
  };

  Future<void> _sheet(Map<String, dynamic> t) async {
    final c = context.read<SessionController>();
    final conn = context.read<AppState>().conn;
    await showModalBottomSheet<void>(
      context: context,
      builder: (s) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'T${t['number']} · ${t['title']}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                children: [
                  for (final st in _statuses)
                    Pill(
                      st,
                      on: t['status'] == st,
                      onTap: () async {
                        Navigator.pop(s);
                        try {
                          await conn?.tskStatus(t['number'] as int, st);
                          await _load();
                        } catch (e) {
                          if (mounted) toast(context, '$e');
                        }
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () async {
                    Navigator.pop(s);
                    await c.send('Start T${t['number']}: ${t['title']}');
                    if (mounted) {
                      toast(
                        context,
                        c.working
                            ? 'Queued for the session'
                            : 'Sent to the session',
                      );
                    }
                  },
                  child: const Text('Ask session to start it'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SessionController>();
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) return Empty('Could not read the tsk board.\n$error');
    final shown = _shown(c.digest.taskMentions);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final f in ['Open', 'Review', 'Done', 'This session'])
                Pill(
                  f,
                  on: filter == f,
                  onTap: () => setState(() => filter = f),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.folder_outlined, size: 15, color: Pal.dim),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  root ?? '',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Pal.dim),
                ),
              ),
              Text(
                '${open.length} open',
                style: const TextStyle(fontSize: 12, color: Pal.dim),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            const Empty('No tasks here.')
          else
            Box(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Column(
                children: [
                  for (var i = 0; i < shown.length; i++)
                    InkWell(
                      onTap: () => _sheet(shown[i]),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          border: i == 0
                              ? null
                              : const Border(top: BorderSide(color: Pal.line)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 46,
                              child: Text(
                                'T${shown[i]['number']}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Pal.dim,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${shown[i]['title']}',
                                    style: const TextStyle(fontSize: 13.5),
                                  ),
                                  if (c.digest.taskMentions.contains(
                                    '${shown[i]['number']}',
                                  ))
                                    const Text(
                                      'this session',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Pal.green,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            _StatusTag('${shown[i]['status']}'),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusTag extends StatelessWidget {
  final String s;
  const _StatusTag(this.s);
  @override
  Widget build(BuildContext context) {
    final color = switch (s) {
      'started' => Pal.amber,
      'review' => Pal.cyan,
      'done' => Pal.green,
      'blocked' => Pal.red,
      _ => Pal.dim,
    };
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        s,
        style: TextStyle(
          fontSize: 10.5,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
