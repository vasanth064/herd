import 'package:flutter/material.dart';

import 'models.dart';

const mono = 'JetBrainsMono';

/// Code must read as typed: `=>` stays two characters, not an arrow.
const noLigatures = [FontFeature.disable('calt'), FontFeature.disable('liga')];

/// The session UI's palette, shared with the design prototype.
class Pal {
  static const bg = Color(0xFF0D0F0E);
  static const bar = Color(0xFF131614);
  static const card = Color(0xFF171A19);
  static const sunk = Color(0xFF0F1211);
  static const line = Color(0xFF232826);
  static const pop = Color(0xFF1E2220);
  static const text = Color(0xFFE6EAE8);
  static const dim = Color(0xFF8D9792);
  static const green = Color(0xFF4CAF50);
  static const red = Color(0xFFFF5252);
  static const amber = Color(0xFFFFC107);
  static const cyan = Color(0xFF26C6DA);
}

class StatusLook {
  final Color color;
  final String glyph;
  final String label;
  const StatusLook(this.color, this.glyph, this.label);
}

/// Status is never colour alone — each carries a glyph and a word so it
/// survives colour-blindness and greyscale.
StatusLook lookFor(AgentStatus s) {
  switch (s) {
    case AgentStatus.blocked:
      return const StatusLook(Color(0xFFFF5252), '!', 'blocked');
    case AgentStatus.working:
      return const StatusLook(Color(0xFFFFC107), '~', 'working');
    case AgentStatus.idle:
      return const StatusLook(Color(0xFF4CAF50), '=', 'idle');
    case AgentStatus.done:
      return const StatusLook(Color(0xFF26C6DA), '+', 'done');
    case AgentStatus.unknown:
      return const StatusLook(Color(0xFF9E9E9E), '?', 'unknown');
  }
}

const _seed = Color(0xFF4CAF50);

ThemeData buildTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: b);
  final dark = b == Brightness.dark;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: dark ? const Color(0xFF0D0F0E) : scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF131614) : scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: dark ? const Color(0xFF171A19) : scheme.surfaceContainerHighest,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
    listTileTheme: const ListTileThemeData(minVerticalPadding: 10),
  );
}

/// A coloured dot plus its glyph. Minimum 44dp tap targets are enforced by the
/// widgets that host this, not by the dot itself.
class StatusDot extends StatelessWidget {
  final AgentStatus status;
  final double size;
  const StatusDot(this.status, {super.key, this.size = 10});

  @override
  Widget build(BuildContext context) {
    final look = lookFor(status);
    return Semantics(
      label: look.label,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: look.color, shape: BoxShape.circle),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final AgentStatus status;
  const StatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final look = lookFor(status);
    return Semantics(
      label: 'status ${look.label}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: look.color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: look.color.withValues(alpha: 0.5)),
        ),
        child: Text(
          '${look.glyph} ${look.label}',
          style: TextStyle(
            color: look.color,
            fontSize: 11,
            fontFamily: mono,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
