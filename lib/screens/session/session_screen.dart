import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../session/controller.dart';
import '../../theme.dart';
import '../terminal_screen.dart';
import 'app_tab.dart';
import 'model_picker.dart';
import 'refs_tab.dart';
import 'summary_tab.dart';
import 'tasks_tab.dart';
import 'widgets.dart';

enum SessionTab { summary, refs, app, tasks }

/// One agent pane as a summary: what it is working towards, its steps, what
/// it needs from you, and what it produced. The terminal stays one tap away.
class SessionScreen extends StatefulWidget {
  final String paneId;

  /// Prepared state, for tests; normally the screen makes and polls its own.
  final SessionController? controller;
  const SessionScreen({super.key, required this.paneId, this.controller});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  late final SessionController ctl;
  SessionTab tab = SessionTab.summary;
  int? appPort;
  String appPath = '/';

  @override
  void initState() {
    super.initState();
    ctl =
        widget.controller ??
        (SessionController(context.read<AppState>(), widget.paneId)..start());
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      ctl.start();
    } else if (s == AppLifecycleState.paused) {
      ctl.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ctl.dispose();
    super.dispose();
  }

  void openApp(int port, String path) => setState(() {
    appPort = port;
    appPath = path;
    tab = SessionTab.app;
  });

  Future<void> _openTerminal() async {
    ctl.pause();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TerminalScreen(target: widget.paneId)),
    );
    if (mounted) ctl.start();
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    return ChangeNotifierProvider.value(
      value: ctl,
      child: Consumer<SessionController>(
        builder: (context, c, _) {
          final a = c.agent;
          return Scaffold(
            backgroundColor: Pal.bg,
            appBar: AppBar(
              backgroundColor: Pal.bar,
              titleSpacing: 0,
              title: GestureDetector(
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) > 200) {
                    showContextPanel(context, c);
                  }
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.digest.title ??
                          (a?.title.isNotEmpty == true ? a!.title : 'Session'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        StatusPill(c.status),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            a?.repo ?? '',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Pal.dim,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: GestureDetector(
                    onTap: () => showContextPanel(context, c),
                    child: ContextRing(c.contextUsed),
                  ),
                ),
              ],
            ),
            body: Column(
              children: [
                _Tabs(
                  tab: tab,
                  refs: c.digest.links.length + c.digest.files.length,
                  onTab: (t) => setState(() => tab = t),
                  onTerminal: _openTerminal,
                ),
                if (c.error != null && !c.loaded)
                  Expanded(
                    child: Empty('Could not read this session.\n${c.error}'),
                  )
                else
                  Expanded(
                    child: switch (tab) {
                      SessionTab.summary => SummaryTab(onOpenPort: openApp),
                      SessionTab.refs => RefsTab(onOpenPort: openApp),
                      SessionTab.app => AppTab(
                        key: ValueKey('$appPort$appPath'),
                        initialPort: appPort,
                        initialPath: appPath,
                      ),
                      SessionTab.tasks => const TasksTab(),
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  final SessionTab tab;
  final int refs;
  final ValueChanged<SessionTab> onTab;
  final VoidCallback onTerminal;
  const _Tabs({
    required this.tab,
    required this.refs,
    required this.onTab,
    required this.onTerminal,
  });

  @override
  Widget build(BuildContext context) {
    Widget chip(
      IconData icon,
      String label,
      bool on,
      VoidCallback tap, {
      int count = 0,
    }) {
      final body = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: on ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: on ? Pal.green : Pal.dim),
          if (on) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Pal.green,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (count > 0) ...[
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Pal.cyan.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  color: Pal.cyan,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      );
      final box = Semantics(
        button: true,
        selected: on,
        label: label,
        child: InkWell(
          onTap: tap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: on ? const Color(0xFF1F2B21) : Pal.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: on ? Pal.green.withValues(alpha: 0.4) : Pal.line,
              ),
            ),
            child: body,
          ),
        ),
      );
      return on ? Expanded(child: box) : box;
    }

    return Container(
      color: Pal.bar,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Row(
        children: [
          chip(
            Icons.dashboard_rounded,
            'Summary',
            tab == SessionTab.summary,
            () => onTab(SessionTab.summary),
          ),
          const SizedBox(width: 6),
          chip(
            Icons.link_rounded,
            'Refs',
            tab == SessionTab.refs,
            () => onTab(SessionTab.refs),
            count: refs,
          ),
          const SizedBox(width: 6),
          chip(
            Icons.web_rounded,
            'App',
            tab == SessionTab.app,
            () => onTab(SessionTab.app),
          ),
          const SizedBox(width: 6),
          chip(
            Icons.checklist_rounded,
            'Tasks',
            tab == SessionTab.tasks,
            () => onTab(SessionTab.tasks),
          ),
          const SizedBox(width: 6),
          chip(Icons.terminal_rounded, 'Terminal', false, onTerminal),
        ],
      ),
    );
  }
}

/// Model label for the composer pill: the preset name when the model and
/// effort match one, otherwise the model alone.
String presetLabel(SessionController c) {
  final m = c.modelName;
  return c.preset?.name ?? (m.isEmpty ? 'Model' : m);
}

String presetDetail(SessionController c) {
  final e = c.effortNow;
  final cap = e == null ? null : e[0].toUpperCase() + e.substring(1);
  final pool = c.modelName.contains(' · ')
      ? c.modelName.split(' · ').last
      : null;
  if (c.preset == null) return [?pool, ?cap].join(' · ');
  return [
    ?pool,
    c.modelName.split(' · ').first.split(' ').first,
    ?cap,
  ].join(' · ');
}
