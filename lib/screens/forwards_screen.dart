import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';

class ForwardsScreen extends StatefulWidget {
  final Profile profile;

  /// True when reached from a connected session — rules can be toggled live.
  final bool live;

  const ForwardsScreen({super.key, required this.profile, this.live = false});

  @override
  State<ForwardsScreen> createState() => _ForwardsScreenState();
}

class _ForwardsScreenState extends State<ForwardsScreen> {
  Profile get p => widget.profile;

  Future<void> _persist() async {
    final app = context.read<AppState>();
    await app.store.saveProfiles(app.profiles);
    if (mounted) setState(() {});
  }

  Future<void> _addPort() async {
    final controller = TextEditingController();
    final form = GlobalKey<FormState>();

    final port = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Forward a port'),
        content: Form(
          key: form,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontFamily: mono),
            decoration: const InputDecoration(
              labelText: 'Port',
              hintText: '3000',
              helperText: 'Reaches the same port on the host',
            ),
            onFieldSubmitted: (_) {
              if (form.currentState!.validate()) {
                Navigator.pop(c, int.parse(controller.text.trim()));
              }
            },
            validator: (v) {
              final n = int.tryParse((v ?? '').trim());
              if (n == null || n < 1 || n > 65535) return 'Enter 1-65535';
              if (p.forwards.any((f) => f.port == n)) {
                return 'Port $n is already forwarded';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(c, int.parse(controller.text.trim()));
              }
            },
            child: const Text('Forward'),
          ),
        ],
      ),
    );

    if (port == null) return;
    final rule = ForwardRule(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      port: port,
      autoStart: true,
    );
    p.forwards.add(rule);
    await _persist();
    if (widget.live) await _toggle(rule, true);
  }

  Future<void> _delete(ForwardRule r) async {
    final app = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove port ${r.port}?'),
        content: const Text('The forward stops and the rule is deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await app.stopForward(r);
    p.forwards.removeWhere((f) => f.id == r.id);
    await _persist();
  }

  Future<void> _toggle(ForwardRule r, bool on) async {
    final app = context.read<AppState>();
    if (on) {
      final err = await app.startForward(r);
      if (err != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
      }
    } else {
      await app.stopForward(r);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Ports')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPort,
        icon: const Icon(Icons.add),
        label: const Text('Port'),
      ),
      body: p.forwards.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Forward a port to open a server running on the host '
                  "in this phone's browser.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: p.forwards.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (c, i) {
                final r = p.forwards[i];
                final active = app.forwardActive(r);
                return Dismissible(
                  key: ValueKey(r.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: const Color(0xFFFF5252).withValues(alpha: 0.25),
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete_outline),
                  ),
                  onDismissed: (_) async {
                    await app.stopForward(r);
                    p.forwards.remove(r);
                    await _persist();
                  },
                  child: ListTile(
                    leading: Icon(
                      Icons.circle,
                      size: 10,
                      color: active
                          ? const Color(0xFF4CAF50)
                          : Theme.of(context).hintColor,
                    ),
                    title: Text(
                      '${r.port}',
                      style: const TextStyle(
                        fontFamily: mono,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      'localhost:${r.port}',
                      style: TextStyle(
                        fontFamily: mono,
                        fontSize: 12,
                        color: active
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).hintColor,
                      ),
                    ),
                    onTap: active
                        ? () => launchUrl(
                              Uri.parse(r.url),
                              mode: LaunchMode.externalApplication,
                            )
                        : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (active)
                          IconButton(
                            tooltip: 'Open in browser',
                            icon: const Icon(Icons.open_in_browser),
                            onPressed: () => launchUrl(
                              Uri.parse(r.url),
                              mode: LaunchMode.externalApplication,
                            ),
                          ),
                        if (widget.live)
                          Switch(value: active, onChanged: (v) => _toggle(r, v)),
                        IconButton(
                          tooltip: 'Remove',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _delete(r),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
