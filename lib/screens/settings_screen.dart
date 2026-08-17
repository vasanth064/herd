import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _Header('Appearance'),
          RadioGroup<ThemeMode>(
            groupValue: app.themeMode,
            onChanged: (m) => m == null ? null : app.setThemeMode(m),
            child: const Column(
              children: [
                RadioListTile(value: ThemeMode.dark, title: Text('Dark')),
                RadioListTile(value: ThemeMode.light, title: Text('Light')),
                RadioListTile(
                    value: ThemeMode.system, title: Text('Follow system')),
              ],
            ),
          ),
          const Divider(),
          const _Header('Known hosts'),
          if (app.knownHosts.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text('No host keys pinned yet.',
                  style: TextStyle(fontSize: 13)),
            ),
          ...app.knownHosts.entries.map(
            (e) => ListTile(
              title:
                  Text(e.key, style: const TextStyle(fontFamily: mono, fontSize: 13)),
              subtitle: Text(
                e.value,
                style: const TextStyle(fontFamily: mono, fontSize: 10),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: 'Forget',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmForget(context, app, e.key),
              ),
            ),
          ),
          const Divider(),
          const _Header('Remote'),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Clear uploaded images'),
            subtitle: const Text('Removes ~/.herdr-mobile/uploads on the host'),
            enabled: app.conn?.isConnected ?? false,
            onTap: () async {
              try {
                await app.conn?.clearUploads();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Uploads cleared.')));
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('$e')));
                }
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _confirmForget(
      BuildContext context, AppState app, String host) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Forget $host?'),
        content: const Text(
          'The next connection will ask you to verify the fingerprint again. '
          'Only do this if you know the host key legitimately changed.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Forget')),
        ],
      ),
    );
    if (ok == true) await app.forgetHost(host);
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 1,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
