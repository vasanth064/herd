import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import 'terminal_screen.dart';

/// herdr's sidebar as a real screen.
///
/// The sidebar cannot be hidden for the phone alone — herdr applies its UI
/// config server-side, so switching it off would switch it off on the desktop
/// too. Instead the phone stops depending on it: workspaces and their tabs are
/// listed here with room to read them, including the ones running no agent.
class WorkspacesScreen extends StatefulWidget {
  const WorkspacesScreen({super.key});

  @override
  State<WorkspacesScreen> createState() => _WorkspacesScreenState();
}

class _WorkspacesScreenState extends State<WorkspacesScreen> {
  List<WorkspaceInfo> _workspaces = [];
  bool _loading = true;
  String? _error;
  Timer? _poll;

  AppState get app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(
      Duration(milliseconds: (app.active?.pollMs ?? 2000) * 2),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final c = app.conn;
    if (c == null || !c.isConnected) return;
    try {
      final ws = await c.workspaces();
      if (!mounted) return;
      setState(() {
        _workspaces = ws;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _report(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  /// Shared by "new workspace" and "new tab" — both take an optional name and
  /// an optional directory.
  Future<({String label, String cwd})?> _askNameAndDir(String title) async {
    final label = TextEditingController();
    final cwd = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: label,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Name', hintText: 'optional'),
              onSubmitted: (_) => Navigator.pop(c, true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: cwd,
              autocorrect: false,
              style: const TextStyle(fontFamily: mono, fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Directory',
                hintText: 'optional, e.g. ~/Projects/app',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (ok != true) return null;
    return (label: label.text.trim(), cwd: cwd.text.trim());
  }

  Future<void> _createWorkspace() async {
    final v = await _askNameAndDir('New workspace');
    if (v == null) return;
    try {
      await app.conn?.createWorkspace(label: v.label, cwd: v.cwd);
      await _refresh();
    } catch (e) {
      _report(e);
    }
  }

  Future<void> _rename(WorkspaceInfo w) async {
    final ctrl = TextEditingController(text: w.label);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename workspace'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (_) => Navigator.pop(c, true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Rename')),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    try {
      await app.conn?.renameWorkspace(w.id, ctrl.text.trim());
      await _refresh();
    } catch (e) {
      _report(e);
    }
  }

  Future<void> _close(WorkspaceInfo w) async {
    final ok = await _confirm(
      'Close ${w.label}?',
      'This closes ${w.paneCount} pane${w.paneCount == 1 ? '' : 's'} and '
          'anything running in them.',
    );
    if (!ok) return;
    try {
      await app.conn?.closeWorkspace(w.id);
      await _refresh();
    } catch (e) {
      _report(e);
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Close')),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        title: const Text('Workspaces', style: TextStyle(fontSize: 18)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createWorkspace,
        icon: const Icon(Icons.add),
        label: const Text('Workspace'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(fontFamily: mono, fontSize: 12)),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: _workspaces.isEmpty
                      ? ListView(children: const [
                          SizedBox(height: 140),
                          Center(child: Text('No workspaces yet.')),
                        ])
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                          itemCount: _workspaces.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (c, i) => Card(
                            child: _WorkspaceCard(
                              workspace: _workspaces[i],
                              onChanged: _refresh,
                              onRename: () => _rename(_workspaces[i]),
                              onClose: () => _close(_workspaces[i]),
                              askNameAndDir: _askNameAndDir,
                              confirm: _confirm,
                              report: _report,
                            ),
                          ),
                        ),
                ),
    );
  }
}

/// Expands to show the workspace's tabs, agent or not.
class _WorkspaceCard extends StatefulWidget {
  final WorkspaceInfo workspace;
  final Future<void> Function() onChanged;
  final VoidCallback onRename;
  final VoidCallback onClose;
  final Future<({String label, String cwd})?> Function(String) askNameAndDir;
  final Future<bool> Function(String, String) confirm;
  final void Function(Object) report;

  const _WorkspaceCard({
    required this.workspace,
    required this.onChanged,
    required this.onRename,
    required this.onClose,
    required this.askNameAndDir,
    required this.confirm,
    required this.report,
  });

  @override
  State<_WorkspaceCard> createState() => _WorkspaceCardState();
}

class _WorkspaceCardState extends State<_WorkspaceCard> {
  List<TabInfo> _tabs = [];
  bool _loadingTabs = false;
  bool _expanded = false;

  AppState get app => context.read<AppState>();
  WorkspaceInfo get w => widget.workspace;

  Future<void> _loadTabs() async {
    setState(() => _loadingTabs = true);
    try {
      final t = await app.conn?.tabs(w.id) ?? [];
      if (mounted) setState(() => _tabs = t);
    } catch (e) {
      widget.report(e);
    } finally {
      if (mounted) setState(() => _loadingTabs = false);
    }
  }

  Future<void> _newTab() async {
    final v = await widget.askNameAndDir('New tab in ${w.label}');
    if (v == null) return;
    try {
      await app.conn?.createTab(w.id, label: v.label, cwd: v.cwd);
      await _loadTabs();
      await widget.onChanged();
    } catch (e) {
      widget.report(e);
    }
  }

  Future<void> _openTab(TabInfo t) async {
    try {
      await app.conn?.focusTab(t.id);
      final pane = t.paneId;
      if (pane == null) {
        widget.report('That tab has no pane to open.');
        return;
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => TerminalScreen(target: pane)),
      );
    } catch (e) {
      widget.report(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A tab's own label is usually just its number; the agent running in it
    // knows what the work is.
    final byTab = {
      for (final a in context.watch<AppState>().agents) a.tabId: a,
    };
    return ExpansionTile(
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 14),
      onExpansionChanged: (v) {
        _expanded = v;
        if (v && _tabs.isEmpty) _loadTabs();
      },
      leading: SizedBox(
        width: 34,
        child: Row(
          children: [
            StatusDot(w.status),
            const SizedBox(width: 8),
            Text('${w.number}',
                style: TextStyle(
                    fontFamily: mono,
                    fontSize: 13,
                    color: Theme.of(context).hintColor)),
          ],
        ),
      ),
      title: Text(
        w.label,
        style: TextStyle(
          fontWeight: w.focused ? FontWeight.w700 : FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '${w.tabCount} tab${w.tabCount == 1 ? '' : 's'} · '
        '${w.paneCount} pane${w.paneCount == 1 ? '' : 's'}'
        '${w.focused ? ' · focused' : ''}',
        style: const TextStyle(fontSize: 11, fontFamily: mono),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          switch (v) {
            case 'focus':
              try {
                await app.conn?.focusWorkspace(w.id);
                await app.refresh();
              } catch (e) {
                widget.report(e);
              }
            case 'tab':
              await _newTab();
            case 'rename':
              widget.onRename();
            case 'close':
              widget.onClose();
          }
        },
        itemBuilder: (c) => const [
          PopupMenuItem(value: 'focus', child: Text('Focus')),
          PopupMenuItem(value: 'tab', child: Text('New tab')),
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'close', child: Text('Close workspace')),
        ],
      ),
      children: [
        if (_loadingTabs)
          const Padding(
            padding: EdgeInsets.all(12),
            child: LinearProgressIndicator(),
          )
        else ...[
          for (final t in _tabs)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 30, right: 8),
              leading: StatusDot(t.status, size: 8),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      byTab[t.id]?.title.isNotEmpty == true
                          ? byTab[t.id]!.title
                          : t.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            t.focused ? FontWeight.w700 : FontWeight.w400,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!t.hasAgent) ...[
                    const SizedBox(width: 8),
                    Text('shell',
                        style: TextStyle(
                            fontSize: 10,
                            fontFamily: mono,
                            color: Theme.of(context).hintColor)),
                  ],
                ],
              ),
              subtitle: Text(
                [
                  t.id,
                  // A bare number is just the tab's position, already obvious.
                  if (int.tryParse(t.label) == null) t.label,
                  if (byTab[t.id] != null) byTab[t.id]!.agent,
                  '${t.paneCount} pane${t.paneCount == 1 ? '' : 's'}',
                ].join(' · '),
                style: const TextStyle(fontSize: 10, fontFamily: mono),
              ),
              onTap: () => _openTab(t),
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'rename') {
                    final ctrl = TextEditingController(text: t.label);
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Rename tab'),
                        content: TextField(
                          controller: ctrl,
                          autofocus: true,
                          decoration:
                              const InputDecoration(labelText: 'Name'),
                          onSubmitted: (_) => Navigator.pop(c, true),
                        ),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: const Text('Cancel')),
                          FilledButton(
                              onPressed: () => Navigator.pop(c, true),
                              child: const Text('Rename')),
                        ],
                      ),
                    );
                    if (ok == true && ctrl.text.trim().isNotEmpty) {
                      try {
                        await app.conn?.renameTab(t.id, ctrl.text.trim());
                        await _loadTabs();
                      } catch (e) {
                        widget.report(e);
                      }
                    }
                  }
                  if (v == 'close') {
                    final ok = await widget.confirm(
                      'Close tab ${t.label}?',
                      'This closes ${t.paneCount} pane'
                          '${t.paneCount == 1 ? '' : 's'} and anything '
                          'running in them.',
                    );
                    if (!ok) return;
                    try {
                      await app.conn?.closeTab(t.id);
                      await _loadTabs();
                      await widget.onChanged();
                    } catch (e) {
                      widget.report(e);
                    }
                  }
                },
                itemBuilder: (c) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'close', child: Text('Close tab')),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _newTab,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New tab', style: TextStyle(fontSize: 13)),
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  void didUpdateWidget(covariant _WorkspaceCard old) {
    super.didUpdateWidget(old);
    // Keep an open card's tab list in step with the polled workspace counts.
    if (_expanded && old.workspace.tabCount != w.tabCount) _loadTabs();
  }
}
