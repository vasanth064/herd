import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../app_state.dart';
import '../../session/controller.dart';
import '../../theme.dart';
import 'model_picker.dart';
import 'session_screen.dart';
import 'widgets.dart';

const _builtinCommands = [
  'compact',
  'clear',
  'model',
  'effort',
  'review',
  'resume',
  'cost',
  'context',
  'memory',
  'init',
  'plan',
  'mcp',
  'agents',
  'permissions',
  'export',
];

class Composer extends StatefulWidget {
  const Composer({super.key});
  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  final text = TextEditingController();
  final focus = FocusNode();
  List<String> get attachments => context.read<SessionController>().attachments;
  final _speech = SpeechToText();
  bool listening = false;
  bool uploading = false;
  String _beforeVoice = '';

  List<String>? _files;
  List<String>? _commands;
  String? token;

  @override
  void initState() {
    super.initState();
    text.addListener(_onText);
  }

  @override
  void dispose() {
    _speech.stop();
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  void setText(String t) {
    text.text = t;
    text.selection = TextSelection.collapsed(offset: t.length);
    focus.requestFocus();
  }

  void _onText() {
    final m = RegExp(r'(?:^|\s)([@/][^\s]*)$').firstMatch(text.text);
    final next = m?.group(1);
    if (next == token) return;
    setState(() => token = next);
    if (next == null) return;
    if (next.startsWith('@')) _loadFiles();
    if (next.startsWith('/')) _loadCommands();
  }

  String? get _cwd {
    final a = context.read<SessionController>().agent;
    if (a == null) return null;
    return a.foregroundCwd.isNotEmpty ? a.foregroundCwd : a.cwd;
  }

  Future<void> _loadFiles() async {
    if (_files != null) return;
    final cwd = _cwd;
    final conn = context.read<AppState>().conn;
    if (cwd == null || conn == null) return;
    _files = const [];
    final f = await conn.projectFiles(cwd);
    if (mounted) setState(() => _files = f);
  }

  Future<void> _loadCommands() async {
    if (_commands != null) return;
    final cwd = _cwd;
    final conn = context.read<AppState>().conn;
    _commands = _builtinCommands;
    if (cwd == null || conn == null) return;
    final extra = await conn.slashCommands(cwd);
    if (mounted) {
      setState(() => _commands = {..._builtinCommands, ...extra}.toList());
    }
  }

  List<String> get _suggestions {
    final t = token;
    if (t == null) return const [];
    final q = t.substring(1).toLowerCase();
    final src = t.startsWith('@')
        ? (_files ?? const [])
        : (_commands ?? const []);
    final hits = src.where((s) => s.toLowerCase().contains(q)).toList()
      ..sort((a, b) {
        final ap = a.toLowerCase().split('/').last.startsWith(q) ? 0 : 1;
        final bp = b.toLowerCase().split('/').last.startsWith(q) ? 0 : 1;
        return ap != bp ? ap - bp : a.length - b.length;
      });
    return hits.take(6).toList();
  }

  void _pick(String s) {
    final t = token!;
    final repl = '${t[0]}$s ';
    final cur = text.text;
    setText(cur.substring(0, cur.length - t.length) + repl);
  }

  Future<void> _send() async {
    final c = context.read<SessionController>();
    final body = [
      ...attachments,
      text.text.trim(),
    ].where((s) => s.isNotEmpty).join(' ');
    if (body.isEmpty) return;
    final queued = c.working;
    text.clear();
    setState(attachments.clear);
    try {
      await c.send(body);
      if (mounted && queued) {
        toast(context, 'Queued, sends when the agent is idle');
      }
    } catch (e) {
      if (mounted) {
        setText(body);
        toast(context, '$e');
      }
    }
  }

  Future<void> _attach() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(c, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.image_rounded),
              title: const Text('Photo'),
              onTap: () => Navigator.pop(c, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.description_rounded),
              title: const Text('File'),
              onTap: () => Navigator.pop(c, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final conn = context.read<AppState>().conn;
    if (conn == null) return;
    String? name;
    List<int>? bytes;
    if (choice == 'file') {
      final f = await FilePicker.pickFile();
      name = f?.name;
      bytes = await f?.readAsBytes();
    } else {
      final x = await ImagePicker().pickImage(
        source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 85,
      );
      name = x?.name;
      bytes = await x?.readAsBytes();
    }
    if (name == null || bytes == null) return;
    setState(() => uploading = true);
    try {
      final path = await conn.uploadImage(name, Uint8List.fromList(bytes));
      if (mounted) setState(() => attachments.add('@$path'));
    } catch (e) {
      if (mounted) toast(context, 'Upload failed: $e');
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  Future<void> _voice() async {
    if (listening) {
      await _speech.stop();
      setState(() => listening = false);
      return;
    }
    final ok = await _speech.initialize(
      onStatus: (s) {
        if ((s == 'done' || s == 'notListening') && mounted) {
          setState(() => listening = false);
        }
      },
      onError: (e) {
        if (mounted) {
          setState(() => listening = false);
          toast(context, 'Voice: ${e.errorMsg}');
        }
      },
    );
    if (!ok) {
      if (mounted) toast(context, 'Speech recognition is not available.');
      return;
    }
    _beforeVoice = text.text.isEmpty || text.text.endsWith(' ')
        ? text.text
        : '${text.text} ';
    setState(() => listening = true);
    await _speech.listen(
      onResult: (r) => setText(_beforeVoice + r.recognizedWords),
      listenOptions: SpeechListenOptions(partialResults: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SessionController>();
    final sugg = _suggestions;
    return Container(
      color: Pal.bar,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (sugg.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Pal.pop,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF2F3632)),
                ),
                child: Column(
                  children: [
                    for (final s in sugg)
                      ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: Icon(
                          token!.startsWith('@')
                              ? Icons.description_outlined
                              : Icons.bolt_rounded,
                          size: 18,
                          color: Pal.dim,
                        ),
                        title: Text(
                          token!.startsWith('@') ? s : '/$s',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        onTap: () => _pick(s),
                      ),
                  ],
                ),
              ),
            if (attachments.isNotEmpty || uploading)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < attachments.length; i++)
                      InputChip(
                        avatar: const Icon(Icons.image_rounded, size: 16),
                        label: Text(
                          attachments[i].split('/').last,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onDeleted: () =>
                            setState(() => attachments.removeAt(i)),
                      ),
                    if (uploading)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.fromLTRB(8, 4, 6, 6),
              decoration: BoxDecoration(
                color: Pal.card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: listening ? Pal.red : Pal.line),
              ),
              child: Column(
                children: [
                  TextField(
                    controller: text,
                    focusNode: focus,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: listening
                          ? 'Listening…'
                          : c.working
                          ? 'Queue a message…'
                          : 'Message  ·  @ files  / commands',
                      hintStyle: const TextStyle(color: Color(0xFF5D6662)),
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Attach',
                        icon: const Icon(Icons.add_rounded, color: Pal.dim),
                        onPressed: _attach,
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: InkWell(
                            onTap: () => showModelPicker(context, c),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              height: 32,
                              padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                              decoration: BoxDecoration(
                                color: const Color(0xFF222725),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      [
                                        presetLabel(c),
                                        presetDetail(c),
                                      ].where((t) => t.isNotEmpty).join('  '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.expand_more_rounded,
                                    size: 16,
                                    color: Pal.dim,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: listening ? 'Stop dictation' : 'Dictate',
                        icon: Icon(
                          listening
                              ? Icons.mic_rounded
                              : Icons.mic_none_rounded,
                          color: listening ? Pal.red : Pal.dim,
                        ),
                        onPressed: _voice,
                      ),
                      if (c.working)
                        IconButton(
                          tooltip: 'Stop the agent',
                          icon: const Icon(
                            Icons.stop_circle_outlined,
                            color: Pal.red,
                          ),
                          onPressed: () async {
                            await c.stop();
                            if (context.mounted) toast(context, 'Sent Esc');
                          },
                        ),
                      IconButton.filled(
                        tooltip: c.working ? 'Queue' : 'Send',
                        style: IconButton.styleFrom(
                          backgroundColor: c.working ? Pal.amber : Pal.green,
                        ),
                        icon: Icon(
                          c.working
                              ? Icons.schedule_send_rounded
                              : Icons.arrow_upward_rounded,
                          color: Colors.black,
                        ),
                        onPressed: _send,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
