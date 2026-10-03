import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';

import '../../session/controller.dart';
import '../../session/digest.dart';
import '../../session/prompt.dart';
import '../../theme.dart';
import 'agent_chat_screen.dart';
import 'composer.dart';
import 'widgets.dart';

class SummaryTab extends StatefulWidget {
  final void Function(int port, String path)? onOpenPort;
  const SummaryTab({super.key, this.onOpenPort});
  @override
  State<SummaryTab> createState() => _SummaryTabState();
}

class _SummaryTabState extends State<SummaryTab> {
  bool? stepsOpen;

  /// Full conversation instead of the summary, on the same page.
  bool chat = false;

  /// Agents that finished over an hour ago stay hidden unless asked for.
  bool olderAgents = false;
  final composer = GlobalKey<ComposerState>();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SessionController>();
    final d = c.digest;
    final ask = c.prompt;
    final pending = ask == null ? d.pendingAsk : null;
    final asking = ask != null || pending != null;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.dashboard_outlined, size: 18),
                label: Text('Summary'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.chat_bubble_outline_rounded, size: 18),
                label: Text('Chat'),
              ),
            ],
            selected: {chat},
            onSelectionChanged: (v) => setState(() => chat = v.first),
          ),
        ),
        Expanded(
          child: !c.loaded
              ? const Center(child: CircularProgressIndicator())
              : chat
              ? d.chat.isEmpty
                    ? const Empty('No conversation yet.')
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                        itemCount: d.chat.length,
                        itemBuilder: (_, i) =>
                            ChatBubble(d.chat[d.chat.length - 1 - i]),
                      )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                  children: [
                    _steps(d, asking, working: c.working),
                    if (!c.working && !asking && d.lastReply != null) ...[
                      const SizedBox(height: 16),
                      ResultCard(
                        text: d.lastReply!,
                        onOpenPort: widget.onOpenPort,
                      ),
                    ],
                    if (c.subAgents.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _agents(c),
                    ],
                    if (c.queue.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _queue(c),
                    ],
                  ],
                ),
        ),
        if (!chat) _Goal(d),
        if (ask != null)
          _AskDock(child: PromptCard(prompt: ask))
        else if (pending != null)
          _AskDock(child: PendingAskCard(ask: pending))
        else
          Composer(key: composer),
      ],
    );
  }

  Widget _steps(Digest d, bool asking, {required bool working}) {
    final fromTasks = d.steps.isNotEmpty;
    final steps = fromTasks ? d.steps : d.turns(working: working);
    if (steps.isEmpty) {
      if (d.lastReply != null) return const SizedBox.shrink();
      return const Empty('Nothing asked yet.');
    }
    final done = steps.where((s) => s.state == StepStatus.done).length;
    final open = stepsOpen ?? !(asking || done == steps.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          fromTasks ? 'Steps' : 'Your asks',
          trailing: '$done / ${steps.length}',
        ),
        Box(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: done / steps.length,
                  minHeight: 4,
                  backgroundColor: const Color(0xFF0A0C0B),
                  color: Pal.green,
                ),
              ),
              const SizedBox(height: 6),
              if (open)
                for (var i = 0; i < steps.length; i++)
                  _StepRow(steps[i], d.activity, first: i == 0),
              InkWell(
                onTap: () => setState(() => stepsOpen = !open),
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      if (!open)
                        Text(
                          done == steps.length
                              ? 'All steps done'
                              : '$done done · ${steps.length - done} to go',
                          style: const TextStyle(fontSize: 12, color: Pal.dim),
                        ),
                      const Spacer(),
                      Text(
                        open ? 'Hide' : 'Show',
                        style: const TextStyle(fontSize: 12, color: Pal.dim),
                      ),
                      Icon(
                        open
                            ? Icons.expand_less_rounded
                            : Icons.chevron_right_rounded,
                        size: 16,
                        color: Pal.dim,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _agents(SessionController c) {
    final recent = [
      for (final a in c.subAgents)
        if (olderAgents || a.idleSeconds < 3600) a,
    ];
    final hidden = c.subAgents.length - recent.length;
    if (recent.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.history_rounded, size: 18),
          label: Text('Show $hidden earlier agents'),
          onPressed: () => setState(() => olderAgents = true),
        ),
      );
    }
    final running = recent.where((a) => a.running).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          'Agents',
          trailing: running > 0 ? '$running running' : '${recent.length}',
        ),
        Box(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(
            children: [
              for (var i = 0; i < recent.length; i++)
                InkWell(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AgentChatScreen(agent: recent[i]),
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      border: i == 0
                          ? null
                          : const Border(top: BorderSide(color: Pal.line)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          recent[i].running
                              ? Icons.autorenew_rounded
                              : Icons.check_circle_outline_rounded,
                          size: 18,
                          color: recent[i].running ? Pal.amber : Pal.green,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                recent[i].description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13.5),
                              ),
                              Text(
                                [
                                  if (recent[i].type.isNotEmpty) recent[i].type,
                                  recent[i].running
                                      ? 'running'
                                      : 'finished ${_since(recent[i].idleSeconds)}',
                                ].join(' · '),
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: Pal.dim,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: Pal.dim,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (hidden > 0)
          TextButton.icon(
            icon: const Icon(Icons.history_rounded, size: 18),
            label: Text('Show $hidden earlier'),
            onPressed: () => setState(() => olderAgents = true),
          ),
      ],
    );
  }

  static String _since(int s) => s < 3600
      ? '${s ~/ 60}m ago'
      : s < 86400
      ? '${s ~/ 3600}h ago'
      : '${s ~/ 86400}d ago';

  Widget _queue(SessionController c) => Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      const SectionTitle('Queued', trailing: 'sends when idle'),
      for (var i = 0; i < c.queue.length; i++)
        Container(
          margin: const EdgeInsets.only(bottom: 6, left: 40),
          padding: const EdgeInsets.fromLTRB(11, 8, 4, 4),
          decoration: BoxDecoration(
            color: const Color(0xFF1C2A1E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Pal.green.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.queue[i], style: const TextStyle(fontSize: 13)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () async {
                      final t = await c.takeQueued(i);
                      composer.currentState?.setText(t);
                    },
                    child: const Text('Edit', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () => c.sendQueued(i),
                    child: const Text(
                      'Send now',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: Pal.dim,
                    ),
                    onPressed: () => c.dropQueued(i),
                  ),
                ],
              ),
            ],
          ),
        ),
    ],
  );
}

/// Claude's answer for the turn that just ended.
class ResultCard extends StatefulWidget {
  final String text;
  final void Function(int port, String path)? onOpenPort;
  const ResultCard({super.key, required this.text, this.onOpenPort});
  @override
  State<ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends State<ResultCard> {
  bool open = false;

  void _link(String? href) {
    if (href == null) return;
    final u = Uri.tryParse(href);
    if (u == null) return;
    final local = ['localhost', '127.0.0.1', '0.0.0.0'].contains(u.host);
    if (local && u.hasPort && widget.onOpenPort != null) {
      widget.onOpenPort!(u.port, u.path.isEmpty ? '/' : u.path);
    } else {
      launchUrl(u, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final long =
        '\n'.allMatches(widget.text).length > 12 || widget.text.length > 900;
    final body = MarkdownBody(
      data: widget.text,
      selectable: true,
      onTapLink: (_, href, _) => _link(href),
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: const TextStyle(fontSize: 14, height: 1.45),
        code: const TextStyle(
          fontFamily: mono,
          fontSize: 12.5,
          fontFeatures: noLigatures,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Result'),
        Box(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (long && !open)
                SizedBox(
                  height: 260,
                  child: ClipRect(
                    child: ShaderMask(
                      shaderCallback: (r) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white,
                          Colors.white,
                          Colors.transparent,
                        ],
                        stops: [0, 0.75, 1],
                      ).createShader(r),
                      blendMode: BlendMode.dstIn,
                      child: SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: body,
                      ),
                    ),
                  ),
                )
              else
                body,
              if (long)
                TextButton(
                  onPressed: () => setState(() => open = !open),
                  child: Text(open ? 'Show less' : 'Show more'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  final SessionStep step;
  final String? activity;
  final bool first;
  const _StepRow(this.step, this.activity, {required this.first});

  @override
  Widget build(BuildContext context) {
    final done = step.state == StepStatus.done;
    final now = step.state == StepStatus.now;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: first ? null : const Border(top: BorderSide(color: Pal.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            margin: const EdgeInsets.only(top: 1, right: 10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? Pal.green.withValues(alpha: 0.15) : null,
              border: Border.all(
                color: done
                    ? Pal.green
                    : now
                    ? Pal.amber
                    : const Color(0xFF3B4440),
                width: 1.5,
              ),
            ),
            child: done
                ? const Icon(Icons.check_rounded, size: 12, color: Pal.green)
                : now
                ? const Padding(
                    padding: EdgeInsets.all(3),
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: Pal.amber,
                    ),
                  )
                : null,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.subject,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.35,
                    color: done ? Pal.dim : Pal.text,
                    decoration: done ? TextDecoration.lineThrough : null,
                    decorationColor: const Color(0xFF3B4440),
                  ),
                ),
                if (now && (activity ?? step.activeForm) != null)
                  Text(
                    activity ?? step.activeForm!,
                    style: const TextStyle(fontSize: 12, color: Pal.amber),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Goal extends StatelessWidget {
  final Digest d;
  const _Goal(this.d);

  @override
  Widget build(BuildContext context) {
    if (d.goal.isEmpty) return const SizedBox.shrink();
    final last = d.lastPrompt;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: const BoxDecoration(
        color: Color(0xFF111412),
        border: Border(top: BorderSide(color: Pal.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'WORKING TOWARDS',
            style: TextStyle(
              fontSize: 9.5,
              color: Pal.dim,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            d.goal,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, height: 1.35),
          ),
          if (last != null && last != d.goal)
            Text(
              'Last ask: “$last”',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Pal.dim),
            ),
        ],
      ),
    );
  }
}

class _AskDock extends StatelessWidget {
  final Widget child;
  const _AskDock({required this.child});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.6,
    ),
    child: Container(
      color: Pal.bar,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: SafeArea(top: false, child: SingleChildScrollView(child: child)),
    ),
  );
}

/// A menu read off the pane's screen, answered by the keys that menu takes.
class PromptCard extends StatefulWidget {
  final ScreenPrompt prompt;
  const PromptCard({super.key, required this.prompt});
  @override
  State<PromptCard> createState() => _PromptCardState();
}

class _PromptCardState extends State<PromptCard> {
  final other = TextEditingController();
  int? picked;
  bool busy = false;

  @override
  void dispose() {
    other.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) toast(context, '$e');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          picked = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.prompt;
    final c = context.read<SessionController>();
    final approval = p.kind == PromptKind.approval;
    return Box(
      border: Pal.red.withValues(alpha: 0.4),
      color: const Color(0xFF1A1414),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            approval ? 'NEEDS YOU · PERMISSION' : 'NEEDS YOU',
            style: const TextStyle(
              fontSize: 10.5,
              color: Pal.red,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            approval ? p.title : p.question,
            style: const TextStyle(fontSize: 15, height: 1.4),
          ),
          if (!approval && p.title.isNotEmpty)
            Text(p.title, style: const TextStyle(fontSize: 12, color: Pal.dim)),
          if (!approval && p.body != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                p.body!,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: Pal.dim),
              ),
            ),
          if (approval) ...[
            Text(
              p.question,
              style: const TextStyle(fontSize: 13, color: Pal.dim),
            ),
            if (p.body != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0C0B),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Pal.line),
                ),
                child: Text(
                  p.body!,
                  style: const TextStyle(
                    fontFamily: mono,
                    fontFeatures: noLigatures,
                    fontSize: 12,
                    color: Color(0xFFCFE8D0),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 10),
          for (var i = 0; i < p.options.length; i++)
            _OptionRow(
              n: i + 1,
              option: p.options[i],
              picked: picked == i,
              danger: approval && p.options[i].label.startsWith('No'),
              onTap: () {
                setState(() => picked = i);
                _run(() => c.answer(i));
              },
            ),
          if (p.customIndex != null)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: other,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Other — type an answer',
                      filled: true,
                      fillColor: Pal.sunk,
                    ),
                    onSubmitted: (t) => _run(() => c.answerText(t)),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: Pal.green),
                  icon: const Icon(
                    Icons.arrow_upward_rounded,
                    color: Colors.black,
                  ),
                  onPressed: () => _run(() => c.answerText(other.text)),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                busy ? Icons.sync_rounded : Icons.check_rounded,
                size: 14,
                color: Pal.dim,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  busy
                      ? 'Sending…'
                      : 'Checked against the live screen before sending',
                  style: const TextStyle(fontSize: 11.5, color: Pal.dim),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  final int n;
  final PromptOption option;
  final bool picked;
  final bool danger;
  final VoidCallback onTap;
  const _OptionRow({
    required this.n,
    required this.option,
    required this.picked,
    required this.danger,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final rec = option.label.endsWith(' (Recommended)');
    final label = rec
        ? option.label.replaceFirst(' (Recommended)', '')
        : option.label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: picked ? const Color(0xFF1F2B21) : Pal.sunk,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: picked ? Pal.green : Pal.line),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 20,
                child: Text(
                  '$n',
                  style: const TextStyle(
                    fontFamily: mono,
                    fontFeatures: noLigatures,
                    color: Pal.green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: danger ? Pal.red : Pal.text,
                            ),
                          ),
                        ),
                        if (rec) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: Pal.green.withValues(alpha: 0.4),
                              ),
                            ),
                            child: const Text(
                              'REC',
                              style: TextStyle(
                                fontSize: 9,
                                color: Pal.green,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (option.description != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          option.description!,
                          style: const TextStyle(fontSize: 12, color: Pal.dim),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An AskUserQuestion the log shows as unanswered while its menu is not on
/// screen (scrolled, or the terminal is narrower than the menu). Shown for
/// reading; answering waits for the menu.
class PendingAskCard extends StatelessWidget {
  final PendingAsk ask;
  const PendingAskCard({super.key, required this.ask});

  @override
  Widget build(BuildContext context) => Box(
    border: Pal.red.withValues(alpha: 0.4),
    color: const Color(0xFF1A1414),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'NEEDS YOU',
          style: TextStyle(
            fontSize: 10.5,
            color: Pal.red,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 6),
        Text(ask.question, style: const TextStyle(fontSize: 15, height: 1.4)),
        if (ask.header.isNotEmpty)
          Text(
            ask.header,
            style: const TextStyle(fontSize: 12, color: Pal.dim),
          ),
        const SizedBox(height: 8),
        for (var i = 0; i < ask.options.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${i + 1}. ${ask.options[i].label}',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        const SizedBox(height: 4),
        const Text(
          'Waiting for the menu to show on the host…',
          style: TextStyle(fontSize: 11.5, color: Pal.dim),
        ),
      ],
    ),
  );
}
