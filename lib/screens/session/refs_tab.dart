import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_state.dart';
import '../../session/controller.dart';
import '../../session/digest.dart';
import '../../theme.dart';
import 'widgets.dart';

class RefsTab extends StatefulWidget {
  final void Function(int port, String path) onOpenPort;
  const RefsTab({super.key, required this.onOpenPort});
  @override
  State<RefsTab> createState() => _RefsTabState();
}

class _RefsTabState extends State<RefsTab> {
  String filter = 'All';

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SessionController>();
    final links = c.digest.links;
    final files = c.digest.files
        .where(
          (f) =>
              filter != 'Commented' || (c.drafts[f.path]?.isNotEmpty ?? false),
        )
        .toList();
    final showLinks = filter == 'All' || filter == 'Links';
    final showFiles = filter != 'Links';
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Wrap(
          spacing: 6,
          children: [
            for (final f in ['All', 'Links', 'Files', 'Commented'])
              Pill(f, on: filter == f, onTap: () => setState(() => filter = f)),
          ],
        ),
        const SizedBox(height: 14),
        if (showLinks && links.isNotEmpty) ...[
          SectionTitle('Links', trailing: '${links.length}'),
          Box(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < links.length; i++)
                  _Row(
                    first: i == 0,
                    badge: switch (links[i].kind) {
                      LinkKind.pr => ('PR', Pal.green),
                      LinkKind.ci => ('CI', Pal.amber),
                      LinkKind.local => ('APP', Pal.cyan),
                      LinkKind.web => ('WEB', Pal.cyan),
                    },
                    title: links[i].label,
                    subtitle: '${links[i].url} · ${ago(links[i].at)}',
                    trailing: links[i].kind == LinkKind.local
                        ? Icons.web_rounded
                        : Icons.open_in_new_rounded,
                    onTap: () {
                      final port = links[i].localPort;
                      if (port != null) {
                        final u = Uri.parse(links[i].url);
                        final path = u.path.isEmpty ? '/' : u.path;
                        widget.onOpenPort(
                          port,
                          u.hasQuery ? '$path?${u.query}' : path,
                        );
                      } else {
                        launchUrl(
                          Uri.parse(links[i].url),
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (showFiles && files.isNotEmpty) ...[
          SectionTitle('Files', trailing: '${files.length}'),
          Box(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < files.length; i++)
                  _Row(
                    first: i == 0,
                    badge: (
                      files[i].ext.isEmpty ? 'FILE' : files[i].ext,
                      Pal.cyan,
                    ),
                    title: files[i].name,
                    subtitle:
                        '${files[i].dir} · ${ago(files[i].at)}${files[i].edits > 1 ? ' · edited ${files[i].edits}×' : ''}',
                    trailingText: (c.drafts[files[i].path]?.length ?? 0) > 0
                        ? '${c.drafts[files[i].path]!.length} comments'
                        : files[i].created
                        ? 'new'
                        : null,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChangeNotifierProvider.value(
                          value: c,
                          child: ReaderScreen(file: files[i]),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        if ((!showLinks || links.isEmpty) && (!showFiles || files.isEmpty))
          const Empty(
            'Nothing here yet. Links the agent posts and files it '
            'writes show up here.',
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final bool first;
  final (String, Color) badge;
  final String title;
  final String subtitle;
  final IconData? trailing;
  final String? trailingText;
  final VoidCallback onTap;
  const _Row({
    required this.first,
    required this.badge,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.trailingText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: first ? null : const Border(top: BorderSide(color: Pal.line)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Pal.sunk,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Pal.line),
            ),
            child: Text(
              badge.$1.length > 4 ? badge.$1.substring(0, 4) : badge.$1,
              style: TextStyle(
                fontFamily: mono,
                fontFeatures: noLigatures,
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: badge.$2,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: Pal.dim),
                ),
              ],
            ),
          ),
          if (trailingText != null)
            Text(
              trailingText!,
              style: const TextStyle(fontSize: 11, color: Pal.dim),
            ),
          if (trailing != null) Icon(trailing, size: 16, color: Pal.dim),
        ],
      ),
    ),
  );
}

/// A file the session wrote, rendered or raw. Selecting text offers Comment;
/// comments collect per file and go to the session as one message.
class ReaderScreen extends StatefulWidget {
  final FileRef file;
  const ReaderScreen({super.key, required this.file});
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  String? body;
  String? error;
  bool raw = false;
  final selected = ValueNotifier('');

  bool get markdown => widget.file.ext == 'MD' || widget.file.ext == 'MARKDOWN';

  @override
  void dispose() {
    selected.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    raw = !markdown;
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await context.read<AppState>().conn!.readText(widget.file.path);
      if (mounted) setState(() => body = t);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _comment(String quote) async {
    final note = TextEditingController();
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (s) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(s).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.only(left: 8),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: Pal.cyan, width: 3)),
              ),
              child: Text(
                quote,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Pal.dim),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: note,
              autofocus: true,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(hintText: 'Your comment'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(s, false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(s, true),
                    child: const Text('Save comment'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (saved != true || note.text.trim().isEmpty || !mounted) return;
    final c = context.read<SessionController>();
    setState(
      () => (c.drafts[widget.file.path] ??= []).add(
        Comment(quote, note.text.trim()),
      ),
    );
  }

  /// A one-off question about a passage, sent now rather than drafted.
  Future<void> _ask(String quote) async {
    final c = context.read<SessionController>();
    final q = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Ask about this'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '“$quote”',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Pal.dim),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: q,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(hintText: 'Your question'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (ok != true || q.text.trim().isEmpty) return;
    await c.send('In ${widget.file.path}, about "$quote": ${q.text.trim()}');
    if (mounted) {
      toast(context, c.working ? 'Question queued' : 'Question sent');
    }
  }

  Future<void> _review() async {
    final c = context.read<SessionController>();
    await showModalBottomSheet<void>(
      context: context,
      builder: (s) => StatefulBuilder(
        builder: (s, set) {
          final d = c.drafts[widget.file.path] ?? [];
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < d.length; i++)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        radius: 11,
                        backgroundColor: Pal.amber,
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.black,
                          ),
                        ),
                      ),
                      title: Text(
                        d[i].note,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        '“${d[i].quote}”',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: Pal.dim),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          set(() => d.removeAt(i));
                          setState(() {});
                        },
                      ),
                    ),
                  if (d.isEmpty)
                    const Empty('No comments yet. Select text to add one.'),
                  if (d.isNotEmpty)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () async {
                          Navigator.pop(s);
                          await c.sendComments(widget.file.path);
                          if (!mounted) return;
                          setState(() {});
                          toast(
                            context,
                            c.working ? 'Comments queued' : 'Comments sent',
                          );
                        },
                        child: Text(
                          'Send ${d.length} comment${d.length == 1 ? '' : 's'} to session',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SessionController>();
    final n = c.drafts[widget.file.path]?.length ?? 0;
    final content = body == null
        ? Center(
            child: error != null
                ? Empty('Could not read the file.\n$error')
                : const CircularProgressIndicator(),
          )
        : SelectionArea(
            onSelectionChanged: (s) => selected.value = s?.plainText ?? '',
            contextMenuBuilder: (ctx, st) =>
                AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: st.contextMenuAnchors,
                  buttonItems: [
                    ...st.contextMenuButtonItems,
                    ContextMenuButtonItem(
                      label: 'Comment',
                      onPressed: () {
                        final q = selected.value.trim();
                        st.hideToolbar();
                        if (q.isNotEmpty) _comment(q);
                      },
                    ),
                  ],
                ),
            child: raw
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      body!,
                      style: const TextStyle(
                        fontFamily: mono,
                        fontFeatures: noLigatures,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  )
                : Markdown(data: body!, padding: const EdgeInsets.all(18)),
          );
    return Scaffold(
      backgroundColor: Pal.bg,
      appBar: AppBar(
        backgroundColor: Pal.bar,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.file.name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            Text(
              widget.file.dir,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Pal.dim),
            ),
          ],
        ),
        actions: [
          if (markdown)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: false, label: Text('Read')),
                  ButtonSegment(value: true, label: Text('Raw')),
                ],
                selected: {raw},
                onSelectionChanged: (v) => setState(() => raw = v.first),
              ),
            ),
        ],
      ),
      body: content,
      bottomNavigationBar: ValueListenableBuilder<String>(
        valueListenable: selected,
        builder: (context, sel, idle) => sel.trim().isEmpty
            ? idle!
            : SafeArea(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                  decoration: const BoxDecoration(
                    color: Pal.pop,
                    border: Border(top: BorderSide(color: Pal.cyan)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.only(left: 8),
                          decoration: const BoxDecoration(
                            border: Border(
                              left: BorderSide(color: Pal.cyan, width: 3),
                            ),
                          ),
                          child: Text(
                            sel.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: Pal.dim,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        tooltip: 'Ask about this',
                        icon: const Icon(Icons.help_outline_rounded),
                        onPressed: () => _ask(sel.trim()),
                      ),
                      FilledButton.icon(
                        icon: const Icon(Icons.add_comment_rounded, size: 18),
                        label: const Text('Comment'),
                        onPressed: () => _comment(sel.trim()),
                      ),
                    ],
                  ),
                ),
              ),
        child: SafeArea(
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            decoration: const BoxDecoration(
              color: Pal.bar,
              border: Border(top: BorderSide(color: Pal.line)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.add_comment_outlined,
                  size: 18,
                  color: Pal.amber,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    n == 0
                        ? 'Select text to comment'
                        : '$n comment draft${n == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 12.5, color: Pal.amber),
                  ),
                ),
                OutlinedButton(onPressed: _review, child: const Text('Review')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
