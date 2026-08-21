import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'models.dart';

/// Single-quote a value for a POSIX shell. Every user-supplied string reaches
/// the remote host through this — prompts, paths, session names.
String shq(String s) => "'${s.replaceAll("'", r"'\''")}'";

class HerdrException implements Exception {
  final String message;
  final int? exitCode;
  HerdrException(this.message, [this.exitCode]);
  @override
  String toString() => message;
}

class HostKeyChangedException implements Exception {
  final String hostPort;
  final String stored;
  final String offered;
  HostKeyChangedException(this.hostPort, this.stored, this.offered);
  @override
  String toString() =>
      'Host key for $hostPort changed. Stored $stored, server offered $offered.';
}

class AuthException implements Exception {
  final String message;

  /// A handshake the transport dropped, rather than credentials the server
  /// refused — on mobile that is a network flap, and worth retrying.
  final bool retryable;
  AuthException(this.message, {this.retryable = false});
  @override
  String toString() => message;
}

class HerdrNotFoundException implements Exception {
  final String path;
  HerdrNotFoundException(this.path);
  @override
  String toString() => path.startsWith('/')
      ? "No herdr at '$path' on the remote host. Check the path under "
          'Advanced, or install herdr there.'
      : "Could not find '$path' on the remote host. SSH logs in with a "
          'minimal PATH, so set the full path under Advanced — '
          'usually ~/.local/bin/herdr.';
}

/// A keyboard-interactive challenge. Tailscale SSH uses one with no prompts at
/// all to hand over a browser check URL, which is why this cannot just be a
/// password box.
class AuthChallenge {
  final String name;
  final String instruction;

  /// (prompt text, echo the typed characters).
  final List<(String, bool)> prompts;

  const AuthChallenge(this.name, this.instruction, this.prompts);

  String? get url => firstUrl('$instruction $name');
}

final _urlRe = RegExp(r'https?://\S+');

String? firstUrl(String s) => _urlRe.firstMatch(s)?.group(0);

enum ConnState { disconnected, connecting, connected, failed }

/// Owns one SSH connection and speaks `herdr` over it.
class HerdrConnection {
  final Profile profile;

  /// Called with (hostPort, fingerprint) the first time a host is seen.
  /// Returning false aborts the connection.
  final Future<bool> Function(String hostPort, String fingerprint) onNewHost;

  /// Returns the stored fingerprint for a host, or null if unknown.
  final String? Function(String hostPort) knownFingerprint;

  /// Answers a keyboard-interactive challenge. Returning null aborts.
  final Future<List<String>?> Function(AuthChallenge)? onChallenge;

  /// An auth-time banner carrying a link. Tailscale SSH sends its browser
  /// check this way and then holds the handshake open until you finish it, so
  /// showing it only after the connection fails is showing it too late.
  final void Function(String message)? onAuthNotice;

  SSHClient? _client;
  SftpClient? _sftp;
  HostKeyChangedException? _mismatch;
  String? _banner;
  final Map<String, ServerSocket> _forwards = {};

  HerdrConnection(this.profile,
      {required this.onNewHost,
      required this.knownFingerprint,
      this.onChallenge,
      this.onAuthNotice});

  bool get isConnected => _client != null && _client!.isClosed == false;

  String get _hostPort => '${profile.host}:${profile.port}';

  Future<void> connect({String? secret, String? passphrase}) async {
    await close();
    List<SSHKeyPair>? identities;
    if (profile.auth == AuthMethod.key) {
      if (secret == null || secret.isEmpty) {
        throw AuthException('No private key stored for this profile.');
      }
      try {
        identities = SSHKeyPair.fromPem(
          secret,
          (passphrase?.isEmpty ?? true) ? null : passphrase,
        );
      } catch (e) {
        throw AuthException('Could not read the private key: $e');
      }
    }

    final socket = await SSHSocket.connect(
      profile.host,
      profile.port,
      timeout: const Duration(seconds: 15),
    );

    final client = SSHClient(
      socket,
      username: profile.username,
      identities: identities,
      onPasswordRequest:
          profile.auth == AuthMethod.password ? () => secret ?? '' : null,
      // dartssh2 only offers keyboard-interactive when this is set. Without it
      // a Tailscale SSH host never gets to send its browser check and the
      // handshake simply stalls until the socket gives up.
      onUserInfoRequest: (req) async {
        final answer = await onChallenge?.call(AuthChallenge(
          req.name,
          req.instruction,
          [for (final p in req.prompts) (p.promptText, p.echo)],
        ));
        if (answer != null) return answer;
        return req.prompts.isEmpty ? const <String>[] : null;
      },
      onUserauthBanner: (message) {
        _banner = message.trim();
        if (firstUrl(_banner!) != null) onAuthNotice?.call(_banner!);
      },
      // Throwing from inside this callback does not propagate — dartssh2 just
      // tears the transport down and the caller sees a generic "connection
      // closed", which would make a swapped host key look like a network blip.
      // Record it, refuse, and raise the real reason after the handshake dies.
      onVerifyHostKey: (type, fingerprint) async {
        final offered = base64.encode(fingerprint);
        final stored = knownFingerprint(_hostPort);
        if (stored == null) return onNewHost(_hostPort, offered);
        if (stored == offered) return true;
        _mismatch = HostKeyChangedException(_hostPort, stored, offered);
        return false;
      },
    );

    try {
      await client.authenticated;
    } catch (e) {
      client.close();
      final m = _mismatch;
      if (m != null) {
        _mismatch = null;
        throw m;
      }
      // The server's own banner says far more than "auth failed" — Tailscale
      // puts the reason it rejected you there.
      final why = _banner?.isNotEmpty == true ? '\n\n$_banner' : '';
      if (e is SSHAuthAbortError) {
        throw AuthException('${e.message}$why', retryable: true);
      }
      if (e is SSHAuthFailError) throw AuthException('${e.message}$why');
      rethrow;
    }
    _client = client;
    await resolveHerdrPath();
  }

  Future<void> close() async {
    for (final s in _forwards.values) {
      await s.close();
    }
    _forwards.clear();
    _sftp?.close();
    _sftp = null;
    _client?.close();
    _client = null;
  }

  SSHClient get _need {
    final c = _client;
    if (c == null) throw HerdrException('Not connected.');
    return c;
  }

  /// Absolute path discovered by [resolveHerdrPath], preferred over the
  /// configured name once known.
  String? _resolved;

  String get herdrPath => _resolved ?? profile.herdrPath;

  /// A non-interactive SSH session gets a bare PATH (`/usr/local/bin:/usr/bin`
  /// on a stock Fedora), so a `herdr` installed in `~/.local/bin` is invisible
  /// even though it works fine in the user's terminal. Rather than making them
  /// hunt for the absolute path, find it: PATH first, then the login shell's
  /// own rc files, then the handful of places it is normally installed.
  Future<String?> resolveHerdrPath() async {
    final name = profile.herdrPath;
    if (name.startsWith('/')) return _resolved = name;
    final probe = 'HERDR_NAME=${shq(name)} sh -c '
        '\'command -v "\$HERDR_NAME" 2>/dev/null '
        '|| "\${SHELL:-/bin/sh}" -ic "command -v \\"\$HERDR_NAME\\"" 2>/dev/null '
        '|| for d in "\$HOME/.local/bin" /usr/local/bin /usr/bin "\$HOME/bin" '
        '/opt/homebrew/bin; do [ -x "\$d/\$HERDR_NAME" ] '
        '&& echo "\$d/\$HERDR_NAME" && break; done\'';
    final res = await _need.runWithResult(probe);
    final out = utf8
        .decode(res.stdout, allowMalformed: true)
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('/'), orElse: () => '');
    return _resolved = out.isEmpty ? null : out;
  }

  String _cmd(List<String> args, {bool scoped = true}) {
    final session = profile.sessionName;
    return [
      shq(herdrPath),
      if (scoped && session != null) ...['--session', shq(session)],
      ...args.map(shq),
    ].join(' ');
  }

  /// Runs a herdr command and returns raw stdout. herdr reports server errors
  /// as JSON on stderr with exit 1, and CLI syntax errors with exit 2.
  Future<String> _run(List<String> args, {bool scoped = true}) async {
    final res = await _need.runWithResult(_cmd(args, scoped: scoped));
    if (res.exitCode == 0) return utf8.decode(res.stdout, allowMalformed: true);

    final err = utf8.decode(res.stderr, allowMalformed: true).trim();

    // herdr reports its own errors as a JSON envelope on stderr. Parse that
    // first: "agent target w99:p99 not found" is a herdr error, not a missing
    // binary, and conflating them tells the user to fix their PATH for a
    // typo'd pane id.
    final envelope = _errorMessage(err);
    if (envelope != null) throw HerdrException(envelope, res.exitCode);

    // No envelope: the shell never reached herdr.
    if (res.exitCode == 127 ||
        err.contains('command not found') ||
        err.contains('no such file or directory')) {
      throw HerdrNotFoundException(profile.herdrPath);
    }
    throw HerdrException(
      err.isEmpty ? 'herdr exited ${res.exitCode}' : err,
      res.exitCode,
    );
  }

  static String? _errorMessage(String stderr) {
    for (final line in stderr.split('\n').reversed) {
      final t = line.trim();
      if (!t.startsWith('{')) continue;
      try {
        final j = jsonDecode(t) as Map<String, dynamic>;
        final e = j['error'];
        if (e is Map && e['message'] is String) return e['message'] as String;
        if (e is String) return e;
      } catch (_) {}
    }
    return null;
  }

  Future<Map<String, dynamic>> _json(List<String> args,
      {bool scoped = true}) async {
    final out = await _run(args, scoped: scoped);
    final line = out
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.startsWith('{'), orElse: () => '');
    if (line.isEmpty) {
      throw HerdrException('herdr returned no JSON for ${args.join(' ')}');
    }
    final j = jsonDecode(line) as Map<String, dynamic>;
    return (j['result'] as Map<String, dynamic>?) ?? j;
  }

  Future<String> version() async {
    final out = await _run(['--version'], scoped: false);
    return out.trim();
  }

  Future<List<SessionInfo>> sessions() async {
    final r = await _json(['session', 'list', '--json'], scoped: false);
    final list = (r['sessions'] as List?) ?? [];
    return list
        .map((s) => SessionInfo.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  Future<List<WorkspaceInfo>> workspaces() async {
    final r = await _json(['workspace', 'list']);
    final list = (r['workspaces'] as List?) ?? [];
    final out = list
        .map((w) => WorkspaceInfo.fromJson(w as Map<String, dynamic>))
        .toList();
    out.sort((a, b) => a.number.compareTo(b.number));
    return out;
  }

  Future<String?> createWorkspace({String? label, String? cwd}) async {
    final r = await _json([
      'workspace',
      'create',
      if (label != null && label.isNotEmpty) ...['--label', label],
      if (cwd != null && cwd.isNotEmpty) ...['--cwd', cwd],
      '--no-focus',
    ]);
    final w = r['workspace'] as Map<String, dynamic>?;
    return w?['workspace_id'] as String?;
  }

  Future<void> focusWorkspace(String id) =>
      _run(['workspace', 'focus', id]).then((_) {});

  Future<void> renameWorkspace(String id, String label) =>
      _run(['workspace', 'rename', id, label]).then((_) {});

  Future<void> closeWorkspace(String id) =>
      _run(['workspace', 'close', id]).then((_) {});

  /// Tabs of a workspace, including those running nothing but a shell, each
  /// paired with a pane so it can be opened regardless.
  Future<List<TabInfo>> tabs(String workspaceId) async {
    final r = await _json(['tab', 'list', '--workspace', workspaceId]);
    var tabs = ((r['tabs'] as List?) ?? [])
        .map((t) => TabInfo.fromJson(t as Map<String, dynamic>))
        .toList();

    try {
      final p = await _json(['pane', 'list', '--workspace', workspaceId]);
      final panes = (p['panes'] as List?) ?? [];
      final firstPaneOfTab = <String, String>{};
      for (final pane in panes.cast<Map<String, dynamic>>()) {
        final tabId = pane['tab_id'] as String?;
        final paneId = pane['pane_id'] as String?;
        if (tabId != null && paneId != null) {
          firstPaneOfTab.putIfAbsent(tabId, () => paneId);
        }
      }
      tabs = tabs.map((t) => t.withPane(firstPaneOfTab[t.id])).toList();
    } catch (_) {
      // Panes are a convenience here; a tab list without them is still useful.
    }

    tabs.sort((a, b) => a.number.compareTo(b.number));
    return tabs;
  }

  Future<void> createTab(String workspaceId, {String? label, String? cwd}) =>
      _run([
        'tab',
        'create',
        '--workspace',
        workspaceId,
        if (label != null && label.isNotEmpty) ...['--label', label],
        if (cwd != null && cwd.isNotEmpty) ...['--cwd', cwd],
        '--no-focus',
      ]).then((_) {});

  Future<void> focusTab(String id) => _run(['tab', 'focus', id]).then((_) {});

  Future<void> renameTab(String id, String label) =>
      _run(['tab', 'rename', id, label]).then((_) {});

  Future<void> closeTab(String id) => _run(['tab', 'close', id]).then((_) {});

  Future<List<AgentInfo>> agents() async {
    final r = await _json(['api', 'snapshot']);
    final snap = (r['snapshot'] as Map<String, dynamic>?) ?? r;
    final list = (snap['agents'] as List?) ?? [];
    final agents = list
        .map((a) => AgentInfo.fromJson(a as Map<String, dynamic>))
        .toList();
    agents.sort((a, b) {
      final k = agentSortKey(a).compareTo(agentSortKey(b));
      return k != 0 ? k : a.agent.compareTo(b.agent);
    });
    return agents;
  }

  /// Raw ANSI bytes for a pane. `recent-unwrapped` joins soft wraps so the
  /// phone re-wraps at its own width instead of inheriting the desktop grid.
  ///
  /// [lines] is omitted by default on purpose: asking for an explicit count
  /// while the agent is working fails with `agent_not_idle`, because
  /// alternate-screen history can only be captured by scrolling while idle.
  /// Without it the read succeeds in either state. Pass a count only when
  /// deliberately pulling deeper history, and be ready for that error.
  /// What the agent is actually asking, for a notification. The pane title is
  /// the session's overall task, which says nothing about the pending question.
  Future<String?> agentQuestion(String target) async {
    try {
      final raw = await _run([
        'agent',
        'read',
        target,
        '--source',
        'recent',
        '--lines',
        '24',
        '--format',
        'text',
      ]);
      final text = plainText(raw);
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  static final _ansi = RegExp(r'\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b\[[0-9;?]*'
      r'[ -/]*[@-~]|\x1b[@-Z\\-_]');
  static final _boxDrawing = RegExp(r'[─-╿]');

  /// Strips escapes and the box-drawing frame agents render prompts inside, so
  /// a notification shows the question rather than a wall of line art.
  static String plainText(String raw, {int keepLines = 10}) {
    final lines = raw
        .replaceAll(_ansi, '')
        .replaceAll(_boxDrawing, ' ')
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return lines.sublist(lines.length > keepLines ? lines.length - keepLines : 0)
        .join('\n');
  }

  Future<String> readAgent(String target, {int? lines}) => _run([
        'agent',
        'read',
        target,
        '--source',
        'recent-unwrapped',
        if (lines != null) ...['--lines', '$lines'],
        '--format',
        'ansi',
      ]);

  /// The pane's real grid, so the phone can render at the width the output was
  /// actually laid out for instead of re-wrapping it into ragged lines.
  Future<({int cols, int rows})?> paneSize(String paneId) async {
    try {
      final r = await _json(['pane', 'layout', '--pane', paneId]);
      final layout = r['layout'] as Map<String, dynamic>?;
      final pane = (layout?['panes'] as List?)?.firstWhere(
        (p) => (p as Map)['pane_id'] == paneId,
        orElse: () => null,
      ) as Map<String, dynamic>?;
      final rect =
          (pane?['rect'] ?? layout?['area']) as Map<String, dynamic>?;
      final w = rect?['width'] as int?;
      final h = rect?['height'] as int?;
      if (w == null || h == null || w < 20) return null;
      return (cols: w, rows: h);
    } catch (_) {
      return null;
    }
  }

  /// Attaches the herdr TUI as a real client in a PTY the size of the phone.
  ///
  /// This is what makes output fit: herdr resizes its panes to the attached
  /// client and, at or below `ui.mobile_width_threshold` (64 columns by
  /// default), switches to its own single-column mobile layout. Verified —
  /// attaching at 46 columns takes a pane from 120x48 to 46x38.
  ///
  /// `agent attach` deliberately is not used here: it streams a pane without
  /// registering as a client, so the pane keeps its desktop geometry and the
  /// output still has to be re-wrapped.
  Future<void> focusPane(String paneId) async {
    final res = await _json(['pane', 'get', paneId]);
    final tab = (res['pane'] as Map<String, dynamic>?)?['tab_id'] as String?;
    if (tab == null) throw HerdrException('Pane $paneId has no tab.');
    await _run(['tab', 'focus', tab]);
  }

  Future<SSHSession> attachAgent(
    String target, {
    required int cols,
    required int rows,
  }) async {
    // Open the TUI where the user tapped. `tab focus` moves the workspace, the
    // tab and the pane in one call; `pane focus` is direction-based and takes
    // no target, and `agent focus` misses a tab running a plain shell.
    await focusPane(target);
    return _need.execute(
      _cmd([]),
      pty: SSHPtyConfig(type: 'xterm-256color', width: cols, height: rows),
    );
  }

  Future<void> prompt(String target, String text) =>
      _run(['agent', 'prompt', target, text]);

  Future<void> sendKeys(String target, List<String> keys) =>
      _run(['agent', 'send-keys', target, ...keys]);

  Future<SftpClient> _sftpClient() async => _sftp ??= await _need.sftp();

  static const uploadDir = '.herdr-mobile/uploads';

  static final _ownerOnly = SftpFileAttrs(
    mode: SftpFileMode(
      groupRead: false,
      groupWrite: false,
      groupExecute: false,
      otherRead: false,
      otherWrite: false,
      otherExecute: false,
    ),
  );

  /// Uploads [bytes] and returns the remote path to paste into a prompt.
  Future<String> uploadImage(String filename, Uint8List bytes) async {
    final sftp = await _sftpClient();
    final home = await _homeDir();
    for (final dir in ['$home/.herdr-mobile', '$home/$uploadDir']) {
      try {
        await sftp.mkdir(dir, _ownerOnly);
      } catch (_) {
        // Already exists — tighten it anyway, then carry on.
        try {
          await sftp.setStat(dir, _ownerOnly);
        } catch (_) {}
      }
    }

    final safe = filename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = '$home/$uploadDir/$stamp-$safe';
    final file = await sftp.open(
      path,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    await file.writeBytes(bytes);
    await file.close();
    return path;
  }

  /// SFTP takes absolute paths and never expands `~`, so the file browser
  /// needs the real home directory.
  Future<String> homeDir() => _homeDir();

  Future<List<SftpName>> listDir(String path) async =>
      (await _sftpClient()).listdir(path);

  Future<SftpFileAttrs> statPath(String path) async =>
      (await _sftpClient()).stat(path);

  /// Head of a remote file. Capped because previews run on a phone and a log
  /// or a video would otherwise be pulled into memory whole.
  Future<Uint8List> readFileHead(String path, int cap) async {
    final f = await (await _sftpClient()).open(path);
    try {
      return await f.readBytes(length: cap);
    } finally {
      await f.close();
    }
  }

  String? _home;
  Future<String> _homeDir() async {
    if (_home != null) return _home!;
    final res = await _need.runWithResult(r'printf %s "$HOME"');
    final h = utf8.decode(res.stdout).trim();
    return _home = h.isEmpty ? '/home/${profile.username}' : h;
  }

  Future<void> clearUploads() =>
      _need.run('rm -rf ${shq("\$HOME/$uploadDir")}').then((_) {});

  bool forwardActive(ForwardRule r) => _forwards.containsKey(r.id);

  Future<void> startForward(ForwardRule rule) async {
    if (_forwards.containsKey(rule.id)) return;
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      rule.port,
    );
    _forwards[rule.id] = server;
    server.listen((socket) async {
      try {
        final channel = await _need.forwardLocal('127.0.0.1', rule.port);
        socket.cast<List<int>>().pipe(channel.sink);
        channel.stream.cast<List<int>>().pipe(socket);
      } catch (_) {
        socket.destroy();
      }
    });
  }

  Future<void> stopForward(ForwardRule rule) async {
    final s = _forwards.remove(rule.id);
    await s?.close();
  }
}
