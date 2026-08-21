import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../app_state.dart';
import '../keys.dart';
import '../models.dart';
import '../theme.dart';
import 'files_screen.dart';

/// Attaches the herdr TUI over a PTY sized to this screen.
///
/// herdr resizes its panes to the attached client and, at or below its
/// `ui.mobile_width_threshold` (64 columns), renders its own single-column
/// mobile layout — including its own scroll overlay. Scrolling is therefore
/// herdr's: a finger drag becomes mouse-wheel reports that it acts on, the
/// same way any terminal emulator drives it.
class TerminalScreen extends StatefulWidget {
  final String target;
  const TerminalScreen({super.key, required this.target});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late String target;
  late Terminal terminal;
  final _termController = TerminalController();
  final _input = TextEditingController();
  final _inputFocus = FocusNode();

  SSHSession? _session;
  StreamSubscription<Uint8List>? _outSub;
  StreamSubscription<Uint8List>? _errSub;
  bool _attaching = false;

  bool _loading = true;
  String? _error;
  bool _sending = false;
  bool _uploading = false;
  final _modifiers = <String>{};

  /// Touch scrolling.
  ///
  /// xterm's own drag-to-scroll never fires under a finger: it puts an
  /// InfiniteScrollView *outside* TerminalView's own Scrollable, and on touch
  /// the inner one claims the vertical drag. On the alternate screen it has no
  /// scrollback, so it scrolls nowhere and swallows the gesture.
  ///
  /// So read raw pointer events instead — a Listener sits outside the gesture
  /// arena and always gets them — and emit SGR wheel reports down the PTY,
  /// which is exactly what a desktop terminal sends and what herdr scrolls on.
  int? _dragPointer;
  Offset _dragLast = Offset.zero;
  double _dragAccum = 0;
  Size _termBox = Size.zero;

  /// Hides the app bar so the pane gets the whole screen. herdr already draws
  /// its own header with the tab and agent counts, so ours is duplication that
  /// costs rows.
  bool _immersive = false;

  AppState get app => context.read<AppState>();
  Profile? get profile => app.active;

  @override
  void initState() {
    super.initState();
    target = widget.target;
    _start();
  }

  @override
  void dispose() {
    _teardown();
    _input.dispose();
    _inputFocus.dispose();
    _termController.dispose();
    super.dispose();
  }

  void _teardown() {
    _outSub?.cancel();
    _errSub?.cancel();
    _outSub = null;
    _errSub = null;
    _session?.close();
    _session = null;
  }

  void _start() {
    _teardown();
    terminal = Terminal(maxLines: profile?.scrollbackLines ?? 5000);
    _loading = true;
    _error = null;
    // Attach only once the view is laid out, so the PTY opens at the real
    // screen size and herdr lays the pane out for this phone.
    WidgetsBinding.instance.addPostFrameCallback((_) => _attach());
  }

  Future<void> _attach() async {
    final c = app.conn;
    if (c == null || _attaching) return;
    if (terminal.viewWidth < 2 || terminal.viewHeight < 2) {
      // Not measured yet; try again next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _attach());
      return;
    }
    _attaching = true;
    try {
      final s = await c.attachAgent(
        target,
        cols: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      if (!mounted) {
        s.close();
        return;
      }
      _session = s;
      terminal.onOutput = (data) => s.write(utf8.encode(data));
      terminal.onResize = (w, h, pw, ph) => s.resizeTerminal(w, h, pw, ph);
      _outSub = s.stdout.listen(_onBytes);
      _errSub = s.stderr.listen(_onBytes);
      s.done.then((_) {
        if (mounted) setState(() => _error = 'Detached from herdr.');
      });
      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    } finally {
      _attaching = false;
    }
  }

  void _onBytes(Uint8List data) {
    terminal.write(utf8.decode(data, allowMalformed: true));
    if (_loading && mounted) setState(() => _loading = false);
  }

  // ---- touch scrolling ----------------------------------------------------

  /// One wheel notch per cell of travel, reported at the cell under the finger.
  /// herdr enables SGR mouse mode (`?1006h`), so button 64 is wheel-up and 65
  /// is wheel-down.
  void _sendWheel({required bool up, required Offset at}) {
    final s = _session;
    if (s == null) return;
    final cols = terminal.viewWidth;
    final rows = terminal.viewHeight;
    if (cols < 1 || rows < 1 || _termBox.isEmpty) return;
    final col =
        ((at.dx / (_termBox.width / cols)).floor() + 1).clamp(1, cols);
    final row =
        ((at.dy / (_termBox.height / rows)).floor() + 1).clamp(1, rows);
    s.write(utf8.encode('\x1b[<${up ? 64 : 65};$col;${row}M'));
  }

  double get _cellHeight {
    final rows = terminal.viewHeight;
    if (rows < 1 || _termBox.isEmpty) return 18;
    return _termBox.height / rows;
  }

  void _onPointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch) return;
    _dragPointer = e.pointer;
    _dragLast = e.localPosition;
    _dragAccum = 0;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _dragPointer) return;
    _dragAccum += e.localPosition.dy - _dragLast.dy;
    _dragLast = e.localPosition;

    final step = _cellHeight;
    while (_dragAccum.abs() >= step) {
      // Dragging down reveals earlier output, which is a wheel-up.
      final up = _dragAccum > 0;
      _sendWheel(up: up, at: e.localPosition);
      _dragAccum -= up ? step : -step;
    }
  }

  void _endDrag(int pointer) {
    if (pointer == _dragPointer) {
      _dragPointer = null;
      _dragAccum = 0;
    }
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      // Atomic submit: herdr honours the pane's bracketed-paste mode and the
      // encoded Enter, which typing the text down the PTY would not.
      await app.conn?.prompt(target, text);
      _input.clear();
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Keys go down the PTY so herdr's own UI receives them. Routing them
  /// through `agent send-keys` would deliver them to the agent's pane instead.
  void _key(String name) {
    final mods = Set<String>.from(_modifiers);
    setState(_modifiers.clear);
    final s = _session;
    if (s == null) return;
    final bytes = keyBytes(name, mods);
    if (bytes == null) {
      _snack('No encoding for "$name".');
      return;
    }
    s.write(utf8.encode(bytes));
  }

  Future<void> _attachImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(c, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(c, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picked = await ImagePicker().pickImage(source: source);
    if (picked == null) return;
    setState(() => _uploading = true);
    try {
      final bytes = await picked.readAsBytes();
      final path = await app.conn!.uploadImage(picked.name, bytes);
      // Inserted unsent — you almost always want to type alongside it.
      final t = _input.text;
      final sep = t.isEmpty || t.endsWith(' ') ? '' : ' ';
      _input.text = '$t$sep$path ';
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
      _inputFocus.requestFocus();
    } catch (e) {
      _snack('Upload failed: $e'); // typed text is left untouched
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _setFont(double delta) async {
    final p = profile;
    if (p == null) return;
    setState(() => p.fontSize = (p.fontSize + delta).clamp(8, 24));
    await app.store.saveProfiles(app.profiles);
  }


  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final me = state.agents.where((a) => a.paneId == target).firstOrNull;
    final fontSize = profile?.fontSize ?? 12;

    return Scaffold(
      appBar: _immersive
          ? null
          : AppBar(
        toolbarHeight: 44,
        titleSpacing: 0,
        title: Row(
          children: [
            if (me != null) ...[
              StatusDot(me.status),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(me?.agent ?? target,
                      style: const TextStyle(fontSize: 16, fontFamily: mono)),
                  if (me != null)
                    Text(
                      me.repo,
                      style: TextStyle(
                          fontSize: 11, color: Theme.of(context).hintColor),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Smaller text',
            onPressed: () => _setFont(-1),
            icon: const Text('A-', style: TextStyle(fontSize: 13)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Larger text',
            onPressed: () => _setFont(1),
            icon: const Text('A+', style: TextStyle(fontSize: 15)),
          ),
          if (me != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Files',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => FilesScreen(
                    path: me.foregroundCwd.isNotEmpty
                        ? me.foregroundCwd
                        : me.cwd,
                  ),
                ),
              ),
              icon: const Icon(Icons.folder_outlined, size: 22),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Full screen',
            onPressed: () => setState(() => _immersive = true),
            icon: const Icon(Icons.fullscreen, size: 22),
          ),
        ],
      ),
      body: Column(
        children: [
          if (me?.status == AgentStatus.blocked)
            Material(
              color: lookFor(AgentStatus.blocked).color.withValues(alpha: 0.15),
              child: InkWell(
                onTap: () => _inputFocus.requestFocus(),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.pan_tool_alt_outlined, size: 16),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text('Waiting on you — tap to answer',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    _termBox = constraints.biggest;
                    return Listener(
                      onPointerDown: _onPointerDown,
                      onPointerMove: _onPointerMove,
                      onPointerUp: (e) => _endDrag(e.pointer),
                      onPointerCancel: (e) => _endDrag(e.pointer),
                      child: Container(
                        color: const Color(0xFF0B0D0C),
                        child: TerminalView(
                          terminal,
                          controller: _termController,
                          theme: TerminalThemes.defaultTheme,
                          textStyle: TerminalStyle(
                              fontSize: fontSize, fontFamily: mono),
                          padding: EdgeInsets.zero,
                          autoResize: true,
                          backgroundOpacity: 1,
                        ),
                      ),
                    );
                  },
                ),
                if (_immersive)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: SafeArea(
                      child: Opacity(
                        opacity: 0.45,
                        child: IconButton(
                          tooltip: 'Show the toolbar',
                          onPressed: () =>
                              setState(() => _immersive = false),
                          icon: const Icon(Icons.fullscreen_exit, size: 20),
                        ),
                      ),
                    ),
                  ),
                if (_loading) const Center(child: CircularProgressIndicator()),
                if (_error != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontFamily: mono, fontSize: 12),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: () => setState(_start),
                            child: const Text('Reattach'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _PromptBar(
            controller: _input,
            focusNode: _inputFocus,
            sending: _sending,
            uploading: _uploading,
            onSend: _send,
            onImage: _attachImage,
          ),
          _KeyRow(
            modifiers: _modifiers,
            onKey: _key,
            onModifier: (m) => setState(() {
              _modifiers.contains(m) ? _modifiers.remove(m) : _modifiers.add(m);
            }),
          ),
        ],
      ),
    );
  }
}

class _PromptBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending, uploading;
  final VoidCallback onSend, onImage;

  const _PromptBar({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.uploading,
    required this.onSend,
    required this.onImage,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      color: Theme.of(context).appBarTheme.backgroundColor,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: scheme.outlineVariant, width: 0.6),
              ),
              padding: const EdgeInsets.only(left: 4, right: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Send an image',
                    visualDensity: VisualDensity.compact,
                    onPressed: uploading ? null : onImage,
                    icon: uploading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.add_photo_alternate_outlined,
                            size: 22),
                  ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                      // Suggestions must stay on: NO_SUGGESTIONS makes Gboard
                      // drop the toolbar strip, which holds voice typing.
                      autocorrect: true,
                      enableSuggestions: true,
                      enableIMEPersonalizedLearning: true,
                      textCapitalization: TextCapitalization.sentences,
                      style: const TextStyle(fontSize: 14, height: 1.3),
                      decoration: InputDecoration(
                        hintText: 'Message the agent…',
                        hintStyle: TextStyle(
                            fontSize: 14, color: Theme.of(context).hintColor),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Material(
              color: scheme.primary,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: sending ? null : onSend,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: sending
                      ? Padding(
                          padding: const EdgeInsets.all(13),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: scheme.onPrimary),
                        )
                      : Icon(Icons.arrow_upward,
                          size: 20, color: scheme.onPrimary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyRow extends StatelessWidget {
  final Set<String> modifiers;
  final void Function(String) onKey;
  final void Function(String) onModifier;

  const _KeyRow({
    required this.modifiers,
    required this.onKey,
    required this.onModifier,
  });

  static const _keys = [
    ('esc', 'ESC'),
    ('tab', 'TAB'),
    ('up', '↑'),
    ('down', '↓'),
    ('left', '←'),
    ('right', '→'),
    ('pgup', 'pgUp'),
    ('pgdn', 'pgDn'),
    ('home', 'home'),
    ('end', 'end'),
    ('backspace', '⌫'),
    ('enter', '⏎'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).appBarTheme.backgroundColor,
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom > 0 ? 0 : 4,
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            children: [
              for (final m in ['ctrl', 'alt', 'shift'])
                _Key(
                  label: m.toUpperCase(),
                  latched: modifiers.contains(m),
                  onTap: () => onModifier(m),
                ),
              const SizedBox(width: 8),
              for (final (name, label) in _keys)
                _Key(label: label, onTap: () => onKey(name)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  final String label;
  final bool latched;
  final VoidCallback onTap;

  const _Key({required this.label, required this.onTap, this.latched = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
        child: Material(
          color: latched ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              constraints: const BoxConstraints(minWidth: 44),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: mono,
                  fontSize: 13,
                  color: latched ? scheme.onPrimary : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
