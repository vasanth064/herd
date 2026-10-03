import 'package:flutter/material.dart';

import '../../herdr.dart';
import '../../session/controller.dart';
import '../../theme.dart';
import 'widgets.dart';

/// Claude Code saves an in-session `/effort` as the model's default for new
/// sessions too, so the change is never made silently.
Future<bool> confirmEffort(
  BuildContext context,
  String model,
  String effort, {
  String decline = 'Model only',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Set effort to $effort?'),
        content: Text(
          'Claude Code also saves this as the default for new $model '
          'sessions on the host.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(decline),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Set effort'),
          ),
        ],
      ),
    ) ??
    false;

/// Context usage with Compact and Clear, dropped down from the top.
Future<void> showContextPanel(BuildContext context, SessionController c) =>
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (ctx, _, _) => Align(
        alignment: Alignment.topCenter,
        child: GestureDetector(
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -200) Navigator.pop(ctx);
          },
          child: Material(
            color: const Color(0xFF1A1E1C),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(22),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: _ContextBody(c),
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (_, a, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(0, -1),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );

class _ContextBody extends StatelessWidget {
  final SessionController c;
  const _ContextBody(this.c);

  @override
  Widget build(BuildContext context) {
    final used = c.contextUsed;
    final window = c.contextWindowSize;
    final k = (used * window / 1000).round();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const SizedBox(width: 40),
            const Expanded(
              child: Text(
                'Context',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Pal.dim),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        Row(
          children: [
            Text(
              '${k}k of ${window ~/ 1000}k',
              style: const TextStyle(fontSize: 13),
            ),
            const Spacer(),
            Text(
              '${(used * 100).round()}%',
              style: const TextStyle(fontSize: 13, color: Pal.dim),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: used,
            minHeight: 8,
            backgroundColor: const Color(0xFF0A0C0B),
            color: used > 0.85 ? Pal.amber : Pal.green,
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            c.digest.compactions == 0
                ? 'Not compacted yet'
                : 'Compacted ${c.digest.compactions}× this session',
            style: const TextStyle(fontSize: 11.5, color: Pal.dim),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.compress_rounded, size: 18),
                label: const Text('Compact'),
                onPressed: () async {
                  Navigator.pop(context);
                  await c.compact();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: Pal.red),
                icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                label: const Text('Clear'),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('Clear this session?'),
                      content: const Text(
                        'Sends /clear. Claude forgets the conversation; files stay as they are.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(d, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(d, true),
                          child: const Text(
                            'Clear',
                            style: TextStyle(color: Pal.red),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (ok != true || !context.mounted) return;
                  Navigator.pop(context);
                  await c.clear();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: const Color(0xFF3B4440),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ],
    );
  }
}

/// The composer's model pill: one slider over model + effort presets, with
/// an Advanced view for any combination.
Future<void> showModelPicker(BuildContext context, SessionController c) =>
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (ctx, _, _) => SafeArea(
        child: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 90),
            child: Material(
              color: Pal.pop,
              borderRadius: BorderRadius.circular(16),
              elevation: 12,
              child: SizedBox(width: 310, child: _Picker(c)),
            ),
          ),
        ),
      ),
      transitionBuilder: (_, a, _, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween(begin: 0.96, end: 1.0).animate(a),
          alignment: Alignment.bottomRight,
          child: child,
        ),
      ),
    );

/// Claude Code's own aliases, for a host whose settings define no picker.
const _aliases = [
  ModelOption('opus', 'Opus', 'For complex work and everyday tasks', 'opus'),
  ModelOption('sonnet', 'Sonnet', 'Most efficient for simpler tasks', 'sonnet'),
  ModelOption('haiku', 'Haiku', 'Fastest for quick answers', 'haiku'),
];

class _Picker extends StatefulWidget {
  final SessionController c;
  const _Picker(this.c);
  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  bool advanced = false;
  late int stop;

  @override
  void initState() {
    super.initState();
    final p = widget.c.preset;
    stop = p == null ? 3 : presets.indexOf(p);
  }

  @override
  Widget build(BuildContext context) =>
      advanced ? _advanced(context) : _slider(context);

  Widget _slider(BuildContext context) {
    final p = presets[stop];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => advanced = true),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    p.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
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
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 28,
              activeTrackColor: const Color(0xFF3A4A3C),
              inactiveTrackColor: const Color(0xFF2C312F),
              thumbColor: Colors.white,
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 13),
              activeTickMarkColor: const Color(0xFF6B736F),
              inactiveTickMarkColor: const Color(0xFF6B736F),
            ),
            child: Slider(
              value: stop.toDouble(),
              max: presets.length - 1.0,
              divisions: presets.length - 1,
              onChanged: (v) => setState(() => stop = v.round()),
              onChangeEnd: (v) async {
                final p = presets[v.round()];
                final withEffort =
                    p.effort == widget.c.effortNow ||
                    await confirmEffort(context, p.model, p.effort);
                await widget.c.applyPreset(p, withEffort: withEffort);
                if (context.mounted) {
                  toast(
                    context,
                    withEffort ? '${p.name} set' : '${p.model} set',
                  );
                }
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < presets.length; i++)
                Text(
                  presets[i].name,
                  style: TextStyle(
                    fontSize: 10,
                    color: i == stop ? Pal.text : Pal.dim,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${p.model} · ${p.effort} effort',
            style: const TextStyle(fontSize: 11.5, color: Pal.dim),
          ),
        ],
      ),
    );
  }

  Widget _advanced(BuildContext context) {
    final c = widget.c;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left_rounded, color: Pal.dim),
                onPressed: () => setState(() => advanced = false),
              ),
              const Expanded(
                child: Text(
                  'Advanced',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.45,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final o
                    in c.catalog.options.isEmpty ? _aliases : c.catalog.options)
                  ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    title: Text(
                      o.label,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: o.description.isEmpty
                        ? null
                        : Text(
                            o.description,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Pal.dim,
                            ),
                          ),
                    trailing: o.label == c.modelName
                        ? const Icon(
                            Icons.check_rounded,
                            color: Color(0xFF5AA9FF),
                          )
                        : null,
                    onTap: () async {
                      Navigator.pop(context);
                      await c.setModel(o.id);
                    },
                  ),
              ],
            ),
          ),
          const Divider(height: 8, color: Color(0xFF2F3632)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Text('Effort', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    children: [
                      for (final e in efforts)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: InkWell(
                            onTap: () async {
                              if (e == c.effortNow) return;
                              if (!await confirmEffort(
                                context,
                                c.modelName.split(' · ').first,
                                e,
                                decline: 'Cancel',
                              )) {
                                return;
                              }
                              await c.setEffort(e);
                              if (mounted) setState(() {});
                            },
                            borderRadius: BorderRadius.circular(7),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: c.effortNow == e
                                      ? Pal.green.withValues(alpha: 0.4)
                                      : Colors.transparent,
                                ),
                              ),
                              child: Text(
                                e,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: c.effortNow == e ? Pal.green : Pal.dim,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 8, color: Color(0xFF2F3632)),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              final nav = Navigator.of(context)..pop();
              showContextPanel(nav.context, c);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  const Text('Context', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${(c.contextUsed * 100).round()}% · Compact, Clear',
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: Pal.dim),
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
    );
  }
}
