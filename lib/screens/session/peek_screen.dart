import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../session/controller.dart';
import '../../theme.dart';
import '../terminal_screen.dart';
import 'session_screen.dart';
import 'summary_tab.dart';
import 'widgets.dart';

/// Swipe between agents and read what each one is saying, nothing more.
/// Only the page on screen polls.
class PeekScreen extends StatefulWidget {
  final String? startPane;
  const PeekScreen({super.key, this.startPane});
  @override
  State<PeekScreen> createState() => _PeekScreenState();
}

class _PeekScreenState extends State<PeekScreen> {
  late final AppState app = context.read<AppState>();
  late final List<AgentInfo> agents = List.of(app.agents);
  late final PageController pages;
  final Map<String, SessionController> _ctl = {};
  int index = 0;

  @override
  void initState() {
    super.initState();
    index = agents.indexWhere((a) => a.paneId == widget.startPane);
    if (index < 0) index = 0;
    pages = PageController(initialPage: index);
    if (agents.isNotEmpty) _focus(index);
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    pages.dispose();
    super.dispose();
  }

  SessionController _for(String pane) =>
      _ctl.putIfAbsent(pane, () => SessionController(app, pane));

  void _focus(int i) {
    for (final c in _ctl.values) {
      c.pause();
    }
    _for(agents[i].paneId).start();
    setState(() => index = i);
  }

  @override
  Widget build(BuildContext context) {
    if (agents.isEmpty) {
      return const Scaffold(body: Empty('No agents running.'));
    }
    return Scaffold(
      backgroundColor: Pal.bg,
      appBar: AppBar(
        backgroundColor: Pal.bar,
        title: const Text('Peek'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              itemCount: agents.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) => _AgentChip(
                agent: agents[i],
                on: i == index,
                onTap: () => pages.animateToPage(
                  i,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                ),
              ),
            ),
          ),
        ),
      ),
      body: PageView.builder(
        controller: pages,
        itemCount: agents.length,
        onPageChanged: _focus,
        itemBuilder: (_, i) => ChangeNotifierProvider.value(
          value: _for(agents[i].paneId),
          child: const _PeekPage(),
        ),
      ),
    );
  }
}

class _AgentChip extends StatelessWidget {
  final AgentInfo agent;
  final bool on;
  final VoidCallback onTap;
  const _AgentChip({
    required this.agent,
    required this.on,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(99),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on ? const Color(0xFF1F2B21) : Pal.card,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(
          color: on ? Pal.green.withValues(alpha: 0.4) : Pal.line,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor(agent.status),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            agent.repo,
            style: TextStyle(fontSize: 12.5, color: on ? Pal.green : Pal.text),
          ),
        ],
      ),
    ),
  );
}

class _PeekPage extends StatefulWidget {
  const _PeekPage();
  @override
  State<_PeekPage> createState() => _PeekPageState();
}

class _PeekPageState extends State<_PeekPage> {
  @override
  Widget build(BuildContext context) {
    final c = context.watch<SessionController>();
    final a = c.agent;
    final chat = c.digest.chat;
    final transcript = c.path != null;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.digest.title ??
                          (a?.title.isNotEmpty == true
                              ? a!.title
                              : a?.agent ?? ''),
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
                        Text(
                          '${a?.repo ?? ''} · ${a?.agent ?? ''}',
                          style: const TextStyle(fontSize: 12, color: Pal.dim),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Terminal',
                icon: const Icon(Icons.terminal_rounded),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TerminalScreen(target: c.paneId),
                  ),
                ),
              ),
              if (a?.agent == 'claude')
                IconButton(
                  tooltip: 'Open session',
                  icon: const Icon(Icons.open_in_full_rounded),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SessionScreen(paneId: c.paneId),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: Pal.line),
        Expanded(
          child: !c.loaded
              ? const Center(child: CircularProgressIndicator())
              : transcript
              ? ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                  itemCount: chat.length,
                  itemBuilder: (_, i) => ChatBubble(chat[chat.length - 1 - i]),
                )
              : SingleChildScrollView(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    c.screen.trimRight(),
                    style: const TextStyle(
                      fontFamily: mono,
                      fontFeatures: noLigatures,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ),
        ),
        if (c.prompt != null)
          Container(
            color: Pal.bar,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: SafeArea(top: false, child: PromptCard(prompt: c.prompt!)),
          ),
      ],
    );
  }
}
