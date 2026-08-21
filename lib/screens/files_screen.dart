import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../herdr.dart';
import '../theme.dart';

enum PreviewKind { image, markdown, text, binary }

const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

const _textExts = {
  'md', 'txt', 'json', 'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'log',
  'csv', 'tsv', 'xml', 'html', 'css', 'scss', 'js', 'mjs', 'ts', 'tsx', 'jsx',
  'dart', 'py', 'rs', 'go', 'java', 'kt', 'kts', 'c', 'h', 'cc', 'cpp', 'hpp',
  'cs', 'sh', 'bash', 'zsh', 'fish', 'sql', 'rb', 'php', 'swift', 'gradle',
  'properties', 'env', 'lock', 'diff', 'patch', 'gitignore', 'editorconfig',
  'graphql', 'proto', 'tf', 'hcl',
};

/// Extension-only guess. A file with no extension at all — README, Makefile,
/// .bashrc — is usually text; the NUL scan in the preview catches the rest.
PreviewKind previewKind(String filename) {
  final name = filename.toLowerCase();
  final dot = name.lastIndexOf('.');
  final ext = dot <= 0 ? '' : name.substring(dot + 1);
  if (_imageExts.contains(ext)) return PreviewKind.image;
  if (ext == 'md' || ext == 'markdown') return PreviewKind.markdown;
  if (ext.isEmpty || _textExts.contains(ext)) return PreviewKind.text;
  return PreviewKind.binary;
}

const textCap = 64 * 1024;
const imageCap = 8 * 1024 * 1024;

int capFor(PreviewKind kind) => kind == PreviewKind.image ? imageCap : textCap;

String humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v < 10 ? v.toStringAsFixed(1) : v.round()} ${units[i]}';
}

/// Dotfiles are the majority of a home directory and bury everything else.
List<SftpName> visible(List<SftpName> entries, bool withHidden,
        {bool dirsOnly = false}) =>
    entries
        .where((e) => withHidden || !e.filename.startsWith('.'))
        .where((e) => !dirsOnly || e.attr.isDirectory || e.attr.isSymbolicLink)
        .toList();

String parentOf(String path) {
  final i = path.lastIndexOf('/');
  if (i <= 0) return '/';
  return path.substring(0, i);
}

String joinPath(String dir, String name) =>
    dir.endsWith('/') ? '$dir$name' : '$dir/$name';

String baseName(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// GitHub's reading rules, not its palette: roomy line height, a grey-barred
/// blockquote, bordered tables and boxed code.
MarkdownStyleSheet githubStyle(BuildContext context) {
  final theme = Theme.of(context);
  final border = theme.dividerColor;
  final base = theme.textTheme.bodyMedium!.copyWith(fontSize: 14, height: 1.55);
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: base,
    listBullet: base,
    blockSpacing: 14,
    h1: base.copyWith(fontSize: 26, fontWeight: FontWeight.w700, height: 1.3),
    h1Padding: const EdgeInsets.only(bottom: 6),
    h2: base.copyWith(fontSize: 21, fontWeight: FontWeight.w700, height: 1.3),
    h2Padding: const EdgeInsets.only(bottom: 6),
    h3: base.copyWith(fontSize: 17, fontWeight: FontWeight.w700),
    h4: base.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
    h5: base.copyWith(fontWeight: FontWeight.w700),
    h6: base.copyWith(color: theme.hintColor, fontWeight: FontWeight.w700),
    code: base.copyWith(
      fontFamily: mono,
      fontSize: 12.5,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
    ),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: theme.cardTheme.color,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: border),
    ),
    blockquote: base.copyWith(color: theme.hintColor),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: border, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
    tableBorder: TableBorder.all(color: border),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    tableHead: base.copyWith(fontWeight: FontWeight.w700),
    tableBody: base.copyWith(fontSize: 13),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: border, width: 2)),
    ),
    a: TextStyle(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary.withValues(alpha: 0.4),
    ),
  );
}

/// An image referenced by a document on the remote host: pulled over the same
/// SFTP connection, since nothing local can resolve `./docs/shot.png`.
class _RemoteImage extends StatefulWidget {
  final String dir;
  final Uri uri;
  const _RemoteImage({required this.dir, required this.uri});

  @override
  State<_RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<_RemoteImage> {
  // Started once: a FutureBuilder fed from build() would re-read megabytes on
  // every rebuild the surrounding document triggers.
  Future<Uint8List>? _load;

  @override
  void initState() {
    super.initState();
    final uri = widget.uri;
    if (uri.hasScheme && uri.scheme != 'file') return;
    final path =
        uri.path.startsWith('/') ? uri.path : joinPath(widget.dir, uri.path);
    final c = context.read<AppState>().conn;
    if (c == null || !c.isConnected) return;
    _load = _read(c, path);
  }

  Future<Uint8List> _read(HerdrConnection c, String path) async {
    final size = (await c.statPath(path)).size ?? 0;
    if (size > imageCap) throw 'too large';
    return c.readFileHead(path, imageCap);
  }

  @override
  Widget build(BuildContext context) {
    final uri = widget.uri;
    if (uri.hasScheme && uri.scheme != 'file') {
      return Image.network(uri.toString(), errorBuilder: (_, _, _) => _missing());
    }
    final load = _load;
    if (load == null) return _missing();
    return FutureBuilder<Uint8List>(
      future: load,
      builder: (c, snap) {
        if (snap.hasError) return _missing();
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: LinearProgressIndicator(),
          );
        }
        return Image.memory(
          snap.data!,
          cacheWidth: (MediaQuery.of(context).size.width *
                  MediaQuery.of(context).devicePixelRatio)
              .round(),
          errorBuilder: (_, _, _) => _missing(),
        );
      },
    );
  }

  Widget _missing() => Text(
        '[image: ${widget.uri.path.split('/').last}]',
        style: TextStyle(
            fontFamily: mono, fontSize: 11, color: Theme.of(context).hintColor),
      );
}

/// Read-only browser over the profile's SFTP connection.
class FilesScreen extends StatefulWidget {
  final String path;

  /// Directory-picker mode: files are hidden and the screen pops the chosen
  /// path instead of previewing anything.
  final bool picking;

  const FilesScreen({super.key, required this.path, this.picking = false});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  List<SftpName> _entries = [];
  bool _loading = true;
  bool _hidden = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final c = context.read<AppState>().conn;
    if (c == null || !c.isConnected) {
      setState(() {
        _loading = false;
        _error = 'Not connected.';
      });
      return;
    }
    try {
      final list = await c.listDir(widget.path);
      list.removeWhere((e) => e.filename == '.' || e.filename == '..');
      list.sort((a, b) {
        final ad = a.attr.isDirectory, bd = b.attr.isDirectory;
        if (ad != bd) return ad ? -1 : 1;
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _entries = list;
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

  Future<void> _open(SftpName e) async {
    final path = joinPath(widget.path, e.filename);
    var isDir = e.attr.isDirectory;
    if (e.attr.isSymbolicLink) {
      // listdir reports the link, not its target, so a symlinked directory
      // looks like a file until it is followed.
      try {
        isDir = (await context.read<AppState>().conn?.statPath(path))
                ?.isDirectory ??
            false;
      } catch (_) {}
    }
    if (!mounted) return;
    final chosen = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => isDir
            ? FilesScreen(path: path, picking: widget.picking)
            : FilePreviewScreen(path: path),
      ),
    );
    if (chosen != null && mounted) Navigator.pop(context, chosen);
  }

  @override
  Widget build(BuildContext context) {
    final shown = visible(_entries, _hidden, dirsOnly: widget.picking);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 56,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(baseName(widget.path), style: const TextStyle(fontSize: 17)),
            Text(widget.path,
                style: const TextStyle(fontSize: 11, fontFamily: mono),
                overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _hidden ? 'Hide hidden files' : 'Show hidden files',
            icon: Icon(_hidden ? Icons.visibility_off : Icons.visibility,
                size: 22),
            onPressed: () => setState(() => _hidden = !_hidden),
          ),
          if (widget.path != '/')
            IconButton(
              tooltip: 'Parent directory',
              icon: const Icon(Icons.arrow_upward),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => FilesScreen(
                      path: parentOf(widget.path), picking: widget.picking),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: !widget.picking
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context, widget.path),
                  icon: const Icon(Icons.check),
                  label: Text('Use ${baseName(widget.path)}'),
                ),
              ),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontFamily: mono, fontSize: 12)),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: shown.isEmpty
                      ? ListView(children: [
                          const SizedBox(height: 140),
                          Center(
                            child: Text(_entries.isEmpty
                                ? 'Empty directory.'
                                : widget.picking
                                    ? 'No subdirectories here.'
                                    : 'Only hidden files here.'),
                          ),
                        ])
                      : ListView.builder(
                          itemCount: shown.length,
                          itemBuilder: (c, i) {
                            final e = shown[i];
                            final dir = e.attr.isDirectory;
                            final size = e.attr.size;
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                dir
                                    ? Icons.folder_outlined
                                    : previewKind(e.filename) ==
                                            PreviewKind.image
                                        ? Icons.image_outlined
                                        : Icons.description_outlined,
                                size: 20,
                              ),
                              title: Text(e.filename,
                                  style: const TextStyle(
                                      fontSize: 14, fontFamily: mono),
                                  overflow: TextOverflow.ellipsis),
                              subtitle: dir || size == null
                                  ? null
                                  : Text(humanSize(size),
                                      style: const TextStyle(
                                          fontSize: 10, fontFamily: mono)),
                              trailing: dir
                                  ? const Icon(Icons.chevron_right, size: 18)
                                  : null,
                              onTap: () => _open(e),
                            );
                          },
                        ),
                ),
    );
  }
}

class FilePreviewScreen extends StatefulWidget {
  final String path;
  const FilePreviewScreen({super.key, required this.path});

  @override
  State<FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<FilePreviewScreen> {
  Uint8List? _bytes;
  int? _size;
  bool _loading = true;
  String? _error;
  late PreviewKind _kind = previewKind(baseName(widget.path));
  bool _raw = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = context.read<AppState>().conn;
    if (c == null || !c.isConnected) {
      setState(() {
        _loading = false;
        _error = 'Not connected.';
      });
      return;
    }
    try {
      final size = (await c.statPath(widget.path)).size;
      if (_kind == PreviewKind.image && (size ?? 0) > imageCap) {
        throw 'Image is ${humanSize(size!)} — too large to preview.';
      }
      final bytes = _kind == PreviewKind.binary
          ? Uint8List(0)
          : await c.readFileHead(widget.path, capFor(_kind));
      // Extension lied: render the mojibake as "binary" rather than as text.
      if (_kind != PreviewKind.image && bytes.contains(0)) {
        _kind = PreviewKind.binary;
      }
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _size = size;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Widget _truncatedNote(int shown) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          'First ${humanSize(shown)} of ${humanSize(_size!)}.',
          style: TextStyle(
              fontSize: 11, fontFamily: mono, color: Theme.of(context).hintColor),
        ),
      );

  Future<void> _openLink(String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    if (uri.hasScheme && uri.scheme != 'file') {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    // A relative link in a doc points at another file on the same host.
    final path = uri.path.startsWith('/')
        ? uri.path
        : joinPath(parentOf(widget.path), uri.path);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => FilePreviewScreen(path: path)),
    );
  }

  Widget _body() {
    final bytes = _bytes!;
    final truncated = _size != null && bytes.length < _size!;
    switch (_kind) {
      case PreviewKind.markdown when !_raw:
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (truncated) _truncatedNote(bytes.length),
            MarkdownBody(
              data: utf8.decode(bytes, allowMalformed: true),
              selectable: true,
              styleSheet: githubStyle(context),
              extensionSet: md.ExtensionSet.gitHubWeb,
              onTapLink: (_, href, _) => href == null ? null : _openLink(href),
              imageBuilder: (uri, _, _) =>
                  _RemoteImage(dir: parentOf(widget.path), uri: uri),
            ),
          ],
        );
      case PreviewKind.image:
        final dpr = MediaQuery.of(context).devicePixelRatio;
        final w = (MediaQuery.of(context).size.width * dpr).round();
        return InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: Image.memory(
              bytes,
              cacheWidth: w,
              errorBuilder: (_, e, _) => Text('Could not decode this image.',
                  style: TextStyle(color: Theme.of(context).hintColor)),
            ),
          ),
        );
      case PreviewKind.markdown:
      case PreviewKind.text:
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (truncated) _truncatedNote(bytes.length),
            SelectableText(
              utf8.decode(bytes, allowMalformed: true),
              style: const TextStyle(fontFamily: mono, fontSize: 12, height: 1.4),
            ),
          ],
        );
      case PreviewKind.binary:
        return Center(
          child: Text(
            'No preview for this file type'
            '${_size == null ? '' : ' · ${humanSize(_size!)}'}.',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 56,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(baseName(widget.path), style: const TextStyle(fontSize: 17)),
            Text(widget.path,
                style: const TextStyle(fontSize: 11, fontFamily: mono),
                overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          if (_kind == PreviewKind.markdown)
            IconButton(
              tooltip: _raw ? 'Rendered' : 'Source',
              icon: Icon(_raw ? Icons.article_outlined : Icons.code, size: 22),
              onPressed: () => setState(() => _raw = !_raw),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontFamily: mono, fontSize: 12)),
                  ),
                )
              : _body(),
    );
  }
}
