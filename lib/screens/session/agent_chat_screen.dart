import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../herdr.dart';
import '../../session/digest.dart';
import '../../theme.dart';
import 'widgets.dart';

/// One subagent's own conversation, read from its log next to the session's.
class AgentChatScreen extends StatefulWidget {
  final SubAgent agent;
  const AgentChatScreen({super.key, required this.agent});
  @override
  State<AgentChatScreen> createState() => _AgentChatScreenState();
}

class _AgentChatScreenState extends State<AgentChatScreen> {
  final digest = Digest(sidechain: true);
  int _offset = 0;
  bool loaded = false;
  String? error;
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final c = context.read<AppState>().conn;
    if (_busy || c == null) return;
    _busy = true;
    try {
      final r = await c.pollSession(widget.agent.path, _offset, null);
      if (r.size >= 0) {
        if (r.start != _offset && _offset != 0) return;
        digest.addLines(r.lines);
        _offset = r.next;
      }
      if (mounted) {
        setState(() {
          loaded = true;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = digest.chat;
    return Scaffold(
      backgroundColor: Pal.bg,
      appBar: AppBar(
        backgroundColor: Pal.bar,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.agent.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            Text(
              [
                if (widget.agent.type.isNotEmpty) widget.agent.type,
                widget.agent.running ? 'running' : 'finished',
              ].join(' · '),
              style: const TextStyle(fontSize: 12, color: Pal.dim),
            ),
          ],
        ),
      ),
      body: !loaded
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Empty('Could not read this agent.\n$error'),
            )
          : chat.isEmpty
          ? const Empty('Nothing in this agent yet.')
          : ListView.builder(
              reverse: true,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
              itemCount: chat.length,
              itemBuilder: (_, i) => ChatBubble(chat[chat.length - 1 - i]),
            ),
    );
  }
}
