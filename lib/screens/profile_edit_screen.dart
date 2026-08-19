import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../herdr.dart';
import '../models.dart';
import '../theme.dart';
import 'forwards_screen.dart';

class ProfileEditScreen extends StatefulWidget {
  final Profile? profile;
  const ProfileEditScreen({super.key, this.profile});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final _form = GlobalKey<FormState>();
  late Profile p;
  late TextEditingController _name, _host, _port, _user, _herdr;
  final _secret = TextEditingController();
  final _passphrase = TextEditingController();
  String? _keyName;
  bool _advanced = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  bool get isNew => widget.profile == null;

  @override
  void initState() {
    super.initState();
    p = widget.profile?.copy() ??
        Profile(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: '',
          host: '',
          username: '',
        );
    _name = TextEditingController(text: p.name);
    _host = TextEditingController(text: p.host);
    _port = TextEditingController(text: '${p.port}');
    _user = TextEditingController(text: p.username);
    _herdr = TextEditingController(text: p.herdrPath);
    if (!isNew) _keyName = 'stored';
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _user, _herdr, _secret, _passphrase]) {
      c.dispose();
    }
    super.dispose();
  }

  void _collect() {
    p.name = _name.text.trim();
    p.host = _host.text.trim();
    p.port = int.tryParse(_port.text.trim()) ?? 22;
    p.username = _user.text.trim();
    p.herdrPath =
        _herdr.text.trim().isEmpty ? 'herdr' : _herdr.text.trim();
  }

  Future<void> _pickKey() async {
    final file = await FilePicker.pickFile();
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() {
      _secret.text = utf8.decode(bytes, allowMalformed: true);
      _keyName = file.name;
    });
  }

  Future<void> _test() async {
    if (!_form.currentState!.validate()) return;
    _collect();
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final app = context.read<AppState>();
    final conn = HerdrConnection(
      p,
      knownFingerprint: (hp) => app.knownHosts[hp],
      onNewHost: (hp, fp) async {
        final ok = await (app.hostKeyPrompt?.call(hp, fp) ?? Future.value(false));
        if (ok) {
          app.knownHosts[hp] = fp;
          await app.store.saveKnownHosts(app.knownHosts);
        }
        return ok;
      },
      onChallenge: (c) async => app.challengePrompt?.call(c),
      onAuthNotice: (m) => app.showAuthNotice?.call(m),
    );
    String message;
    var ok = false;
    try {
      await conn.connect(
        secret: _secret.text.isNotEmpty
            ? _secret.text
            : await app.store.secret(p.secretKey),
        passphrase: _passphrase.text.isNotEmpty
            ? _passphrase.text
            : await app.store.secret(p.passphraseKey),
      );
      final v = await conn.version();
      final s = await conn.sessions();
      message = 'Connected · $v · ${s.length} session${s.length == 1 ? '' : 's'}';
      ok = true;
    } on HerdrNotFoundException catch (e) {
      message = 'SSH works, but $e';
    } on AuthException catch (e) {
      message = 'Authentication failed: $e';
    } on HostKeyChangedException catch (e) {
      message = '$e';
    } catch (e) {
      message = 'Could not reach ${p.host}:${p.port} — $e';
    } finally {
      app.hideAuthNotice?.call();
      await conn.close();
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = message;
      _testOk = ok;
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    _collect();
    final app = context.read<AppState>();
    if (_secret.text.isNotEmpty) {
      await app.store.setSecret(p.secretKey, _secret.text);
    }
    if (_passphrase.text.isNotEmpty) {
      await app.store.setSecret(p.passphraseKey, _passphrase.text);
    }
    await app.saveProfile(p);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isKey = p.auth == AuthMethod.key;
    final isTailscale = p.auth == AuthMethod.tailscale;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'Add host' : 'Edit host'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              textCapitalization: TextCapitalization.none,
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Give it a name' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _host,
                    decoration: const InputDecoration(labelText: 'Host'),
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'Required' : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _port,
                    decoration: const InputDecoration(labelText: 'Port'),
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim());
                      return n == null || n < 1 || n > 65535 ? '1-65535' : null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _user,
              decoration: const InputDecoration(labelText: 'Username'),
              autocorrect: false,
              validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 20),
            SegmentedButton<AuthMethod>(
              segments: const [
                ButtonSegment(
                  value: AuthMethod.key,
                  label: Text('Private key'),
                  icon: Icon(Icons.key_outlined),
                ),
                ButtonSegment(
                  value: AuthMethod.password,
                  label: Text('Password'),
                  icon: Icon(Icons.password_outlined),
                ),
                ButtonSegment(
                  value: AuthMethod.tailscale,
                  label: Text('Tailscale'),
                  icon: Icon(Icons.shield_outlined),
                ),
              ],
              selected: {p.auth},
              onSelectionChanged: (s) => setState(() {
                p.auth = s.first;
                _secret.clear();
                _keyName = null;
              }),
            ),
            const SizedBox(height: 12),
            if (isKey) ...[
              OutlinedButton.icon(
                onPressed: _pickKey,
                icon: const Icon(Icons.upload_file_outlined),
                label: Text(_keyName == null
                    ? 'Import private key'
                    : 'Key: $_keyName (tap to replace)'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passphrase,
                decoration: const InputDecoration(
                  labelText: 'Key passphrase (if any)',
                ),
                obscureText: true,
              ),
            ] else if (isTailscale)
              const Text(
                'No key or password. Tailscale SSH authorises this device, and '
                'asks you to finish a browser check when it needs one.',
                style: TextStyle(fontSize: 12),
              )
            else
              TextFormField(
                controller: _secret,
                decoration: InputDecoration(
                  labelText: isNew ? 'Password' : 'Password (blank to keep)',
                ),
                obscureText: true,
              ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.network_check),
              label: const Text('Test connection'),
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (_testOk
                          ? const Color(0xFF4CAF50)
                          : const Color(0xFFFF5252))
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _testResult!,
                  style: const TextStyle(fontSize: 12, fontFamily: mono),
                ),
              ),
            ],
            const SizedBox(height: 12),
            ExpansionTile(
              title: const Text('Advanced'),
              tilePadding: EdgeInsets.zero,
              initiallyExpanded: _advanced,
              onExpansionChanged: (v) => _advanced = v,
              children: [
                TextFormField(
                  controller: _herdr,
                  decoration: const InputDecoration(
                    labelText: 'herdr binary path',
                    helperText: 'Absolute path if it is not on PATH',
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                _Slider(
                  label: 'Poll interval',
                  value: p.pollMs.toDouble(),
                  min: 1000,
                  max: 5000,
                  divisions: 4,
                  format: (v) => '${(v / 1000).toStringAsFixed(0)}s',
                  onChanged: (v) => setState(() => p.pollMs = v.round()),
                ),
                _Slider(
                  label: 'Scrollback lines',
                  value: p.scrollbackLines.toDouble(),
                  min: 1000,
                  max: 20000,
                  divisions: 19,
                  format: (v) => '${v.round()}',
                  onChanged: (v) =>
                      setState(() => p.scrollbackLines = v.round()),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.swap_horiz),
                  title: const Text('Port forwards'),
                  subtitle: Text('${p.forwards.length} rule(s)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ForwardsScreen(profile: p),
                    ),
                  ).then((_) => setState(() {})),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  final String label;
  final double value, min, max;
  final int divisions;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  const _Slider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${format(value)}',
            style: const TextStyle(fontSize: 13)),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: format(value),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
