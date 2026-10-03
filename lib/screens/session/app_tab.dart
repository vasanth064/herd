import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../native.dart';
import '../../session/controller.dart';
import '../../theme.dart';
import 'widgets.dart';

const _desktopUA =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/130.0 Safari/537.36';

/// The app the session is running, inside Herd. It is reached directly over
/// the LAN or tailnet when the server listens beyond loopback, and through
/// the SSH connection otherwise.
class AppTab extends StatefulWidget {
  final int? initialPort;
  final String initialPath;
  const AppTab({super.key, this.initialPort, this.initialPath = '/'});
  @override
  State<AppTab> createState() => _AppTabState();
}

class _AppTabState extends State<AppTab> {
  List<({int port, String name})> servers = [];
  int? port;
  String? url;
  String? problem;
  bool loading = true;
  bool desktop = false;
  bool capturing = false;
  ForwardRule? _forward;
  final _shot = GlobalKey();
  WebViewController? web;
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _discover();
  }

  @override
  void dispose() {
    final f = _forward;
    if (f != null) _app.stopForward(f);
    super.dispose();
  }

  Future<void> _discover() async {
    final app = context.read<AppState>();
    final c = context.read<SessionController>();
    try {
      final found = await app.conn!.listeningPorts(c.paneId);
      servers = [
        ...found,
        if (widget.initialPort != null &&
            !found.any((s) => s.port == widget.initialPort))
          (port: widget.initialPort!, name: 'link'),
      ];
    } catch (_) {
      servers = [
        if (widget.initialPort != null)
          (port: widget.initialPort!, name: 'link'),
      ];
    }
    if (!mounted) return;
    if (servers.isEmpty) {
      setState(() => loading = false);
      return;
    }
    await _open(
      widget.initialPort ?? servers.first.port,
      path: widget.initialPort == null ? '/' : widget.initialPath,
    );
  }

  Future<void> _askPort() async {
    final field = TextEditingController();
    final p = await showDialog<int>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Port on the host'),
        content: TextField(
          controller: field,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '5173'),
          onSubmitted: (t) => Navigator.pop(d, int.tryParse(t)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, int.tryParse(field.text)),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    if (p == null || p < 1 || p > 65535 || !mounted) return;
    if (!servers.any((s) => s.port == p)) {
      setState(() => servers = [...servers, (port: p, name: 'port')]);
    }
    await _open(p);
  }

  Future<void> _open(int p, {String path = '/'}) async {
    final app = context.read<AppState>();
    setState(() {
      port = p;
      loading = true;
      problem = null;
    });
    if (_forward != null) {
      await app.stopForward(_forward!);
      _forward = null;
    }
    final host = app.active!.host;
    String? target;
    try {
      final s = await Socket.connect(
        host,
        p,
        timeout: const Duration(milliseconds: 1500),
      );
      s.destroy();
      target = 'http://$host:$p$path';
    } catch (_) {
      final rule = ForwardRule(id: 'app-$p', port: p);
      final err = await app.startForward(rule);
      if (err == null) {
        _forward = rule;
        target = 'http://127.0.0.1:$p$path';
      } else {
        problem = err;
      }
    }
    if (!mounted) return;
    if (target == null) {
      setState(() => loading = false);
      return;
    }
    final ctl = web ?? WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _applyViewport(),
          onWebResourceError: (e) {
            if (e.isForMainFrame ?? true) {
              final why = app.forwardErrors[_forward?.id ?? ''];
              setState(() => problem = why ?? e.description);
            }
          },
        ),
      );
    web = ctl;
    await _desktopMode(ctl, desktop);
    await ctl.loadRequest(Uri.parse(target));
    setState(() {
      url = target;
      loading = false;
    });
  }

  Future<void> _applyViewport() async {
    if (!desktop) return;
    await web?.runJavaScript(
      "var m=document.querySelector('meta[name=viewport]');"
      "if(!m){m=document.createElement('meta');m.name='viewport';document.head.appendChild(m);}"
      "m.content='width=1280';",
    );
  }

  Future<void> _toggleDesktop() async {
    setState(() => desktop = !desktop);
    await _desktopMode(web, desktop);
    await web?.reload();
  }

  Future<void> _landscape() async {
    final u = url;
    if (u == null) return;
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _Landscape(url: u, desktop: desktop),
      ),
    );
    await SystemChrome.setPreferredOrientations(const []);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  Future<void> _screenshot() async {
    final app = context.read<AppState>();
    final c = context.read<SessionController>();
    final box = _shot.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final ratio = MediaQuery.of(context).devicePixelRatio;
    final rect = (box.localToGlobal(Offset.zero) & box.size);
    setState(() => capturing = true);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      final png = await Native.capture(
        Rect.fromLTWH(
          rect.left * ratio,
          rect.top * ratio,
          rect.width * ratio,
          rect.height * ratio,
        ),
      );
      if (png == null) {
        throw StateError('this Android version cannot capture it');
      }
      final path = await app.conn!.uploadImage('app-$port.png', png);
      c.attach(path);
      if (mounted) toast(context, 'Screenshot added to your next message');
    } catch (e) {
      if (mounted) toast(context, 'Screenshot failed: $e');
    } finally {
      if (mounted) setState(() => capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading && web == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (servers.isEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Empty(
            'No server is listening in this session yet.\nLinks to localhost '
            'ports on the Refs tab open here.',
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.add_rounded),
            label: const Text('Open a port'),
            onPressed: _askPort,
          ),
        ],
      );
    }
    final cur = servers.where((s) => s.port == port).firstOrNull;
    return Column(
      children: [
        Container(
          color: Pal.bar,
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Row(
            children: [
              Expanded(
                child: PopupMenuButton<int>(
                  onSelected: (p) => p < 0 ? _askPort() : _open(p),
                  itemBuilder: (_) => [
                    for (final s in servers)
                      PopupMenuItem(
                        value: s.port,
                        child: Text('${s.name} · localhost:${s.port}'),
                      ),
                    const PopupMenuItem(
                      value: -1,
                      child: Text('Another port…'),
                    ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Pal.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Pal.line),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 8,
                          color: problem == null ? Pal.green : Pal.red,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${cur?.name ?? ''} · localhost:$port',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: mono,
                              fontFeatures: noLigatures,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.expand_more_rounded,
                          size: 18,
                          color: Pal.dim,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Reload',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () => web?.reload(),
              ),
              IconButton(
                tooltip: 'Desktop site',
                isSelected: desktop,
                selectedIcon: const Icon(
                  Icons.desktop_windows_rounded,
                  color: Pal.green,
                ),
                icon: const Icon(Icons.desktop_windows_outlined),
                onPressed: _toggleDesktop,
              ),
              IconButton(
                tooltip: 'Landscape',
                icon: const Icon(Icons.screen_rotation_rounded),
                onPressed: _landscape,
              ),
              IconButton(
                tooltip: 'Open in browser',
                icon: const Icon(Icons.open_in_new_rounded),
                onPressed: url == null
                    ? null
                    : () => launchUrl(
                        Uri.parse(url!),
                        mode: LaunchMode.externalApplication,
                      ),
              ),
            ],
          ),
        ),
        Expanded(
          child: problem != null
              ? Empty(
                  problem!.contains('Tailscale')
                      ? problem!
                      : problem!.toLowerCase().contains('refused')
                      ? 'Nothing is listening on port $port on the host. '
                            'Start the server, then reload.'
                      : problem == 'open failed'
                      ? 'The host refused to tunnel to port $port: its sshd '
                            'or SELinux policy blocks that port. Use another '
                            'port, or start the server on 0.0.0.0.'
                      : 'Could not reach localhost:$port.\n$problem',
                )
              : Stack(
                  children: [
                    RepaintBoundary(
                      key: _shot,
                      child: web == null
                          ? const SizedBox.expand()
                          : WebViewWidget(controller: web!),
                    ),
                    if (!capturing)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: FloatingActionButton.extended(
                          heroTag: 'shot',
                          backgroundColor: Pal.card,
                          foregroundColor: Pal.text,
                          icon: const Icon(Icons.photo_camera_rounded),
                          label: const Text('Screenshot to chat'),
                          onPressed: _screenshot,
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Desktop sites need a desktop user agent and, on Android, the wide
/// viewport that webview_flutter switches off by default.
Future<void> _desktopMode(WebViewController? web, bool on) async {
  if (web == null) return;
  await web.setUserAgent(on ? _desktopUA : null);
  final p = web.platform;
  if (p is AndroidWebViewController) await p.setUseWideViewPort(on);
}

class _Landscape extends StatefulWidget {
  final String url;
  final bool desktop;
  const _Landscape({required this.url, required this.desktop});
  @override
  State<_Landscape> createState() => _LandscapeState();
}

class _LandscapeState extends State<_Landscape> {
  final web = WebViewController();

  @override
  void initState() {
    super.initState();
    web.setJavaScriptMode(JavaScriptMode.unrestricted);
    _desktopMode(
      web,
      widget.desktop,
    ).then((_) => web.loadRequest(Uri.parse(widget.url)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        WebViewWidget(controller: web),
        Positioned(
          right: 10,
          top: 10,
          child: IconButton.filledTonal(
            tooltip: 'Exit landscape',
            icon: const Icon(Icons.close_fullscreen_rounded),
            onPressed: () => Navigator.pop(context),
          ),
        ),
      ],
    ),
  );
}
