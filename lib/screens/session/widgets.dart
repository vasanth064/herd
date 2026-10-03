import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../models.dart';
import '../../session/digest.dart';
import '../../theme.dart';

const statusLabel = {
  AgentStatus.blocked: 'Needs you',
  AgentStatus.working: 'Working',
  AgentStatus.idle: 'Idle',
  AgentStatus.done: 'Done',
  AgentStatus.unknown: 'Unknown',
};

Color statusColor(AgentStatus s) => lookFor(s).color;

class StatusPill extends StatelessWidget {
  final AgentStatus status;
  const StatusPill(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        statusLabel[status]!,
        style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final String? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: const TextStyle(
              color: Pal.dim,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.7,
            ),
          ),
        ),
        if (trailing != null)
          Text(trailing!, style: const TextStyle(color: Pal.dim, fontSize: 11)),
      ],
    ),
  );
}

class Box extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? border;
  final Color color;
  const Box({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(14, 12, 14, 12),
    this.border,
    this.color = Pal.card,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: border ?? Pal.line),
    ),
    child: child,
  );
}

class ContextRing extends StatelessWidget {
  final double used;
  const ContextRing(this.used, {super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(4, 4, 9, 4),
    decoration: BoxDecoration(
      color: Pal.card,
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: Pal.line),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 22,
          height: 22,
          child: CustomPaint(painter: _Ring(used)),
        ),
        const SizedBox(width: 6),
        Text(
          '${(used * 100).round()}%',
          style: const TextStyle(
            fontSize: 11,
            color: Pal.dim,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _Ring extends CustomPainter {
  final double v;
  _Ring(this.v);
  @override
  void paint(Canvas c, Size s) {
    final r = Rect.fromLTWH(2, 2, s.width - 4, s.height - 4);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    c.drawArc(r, 0, 2 * pi, false, p..color = const Color(0xFF2A302D));
    c.drawArc(
      r,
      -pi / 2,
      2 * pi * v,
      false,
      p..color = v > 0.85 ? Pal.amber : Pal.green,
    );
  }

  @override
  bool shouldRepaint(_Ring o) => o.v != v;
}

class Pill extends StatelessWidget {
  final String text;
  final bool on;
  final VoidCallback? onTap;
  final IconData? icon;
  const Pill(this.text, {super.key, this.on = false, this.onTap, this.icon});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(99),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
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
          if (icon != null) ...[
            Icon(icon, size: 15, color: on ? Pal.green : Pal.dim),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: TextStyle(fontSize: 12.5, color: on ? Pal.green : Pal.text),
          ),
        ],
      ),
    ),
  );
}

class Empty extends StatelessWidget {
  final String text;
  const Empty(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(color: Pal.dim, fontSize: 13),
    ),
  );
}

void toast(BuildContext context, String m) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(milliseconds: 1800)),
    );
}

String ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// One line of a session's conversation: your prompt, Claude's reply, or a
/// tool call reduced to a dim one-liner.
class ChatBubble extends StatelessWidget {
  final ChatLine line;
  const ChatBubble(this.line, {super.key});

  @override
  Widget build(BuildContext context) {
    switch (line.role) {
      case ChatRole.tool:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
          child: Row(
            children: [
              const Icon(
                Icons.subdirectory_arrow_right_rounded,
                size: 14,
                color: Pal.dim,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  line.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Pal.dim),
                ),
              ),
            ],
          ),
        );
      case ChatRole.you:
      case ChatRole.claude:
        final you = line.role == ChatRole.you;
        return Align(
          alignment: you ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.84,
            ),
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            decoration: BoxDecoration(
              color: you ? const Color(0xFF1C2A1E) : Pal.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: you ? Pal.green.withValues(alpha: 0.3) : Pal.line,
              ),
            ),
            child: you
                ? Text(
                    line.text,
                    style: const TextStyle(fontSize: 13.5, height: 1.4),
                  )
                : MarkdownBody(
                    data: line.text.length > 3000
                        ? '${line.text.substring(0, 3000)}…'
                        : line.text,
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                        .copyWith(
                          p: const TextStyle(fontSize: 13.5, height: 1.4),
                          code: const TextStyle(
                            fontFamily: mono,
                            fontSize: 12,
                            fontFeatures: noLigatures,
                          ),
                        ),
                  ),
          ),
        );
    }
  }
}
