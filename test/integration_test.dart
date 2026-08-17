@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/herdr.dart';
import 'package:herdr_mobile/models.dart';

/// Exercises the real stack: dartssh2 -> sshd -> herdr CLI -> herdr server.
///
/// Needs a throwaway sshd (see test/integration_setup.sh) so nothing about the
/// developer's own SSH configuration is touched. Skips itself when that sshd
/// is not listening, so `flutter test` stays green on a machine without it.
///
///   bash test/integration_setup.sh up
///   flutter test test/integration_test.dart --tags integration
///   bash test/integration_setup.sh down
void main() {
  const dir = '/tmp/herdr-itest';
  final keyFile = File('$dir/testkey');
  final missing = !keyFile.existsSync();

  late Profile profile;
  late HerdrConnection conn;
  final pinned = <String, String>{};

  setUpAll(() async {
    if (!keyFile.existsSync()) return;
    profile = Profile(
      id: 'itest',
      name: 'itest',
      host: '127.0.0.1',
      port: 2222,
      username: Platform.environment['USER'] ?? 'runner',
      // Non-interactive SSH has a minimal PATH; this is why the setting exists.
      herdrPath: '${Platform.environment['HOME']}/.local/bin/herdr',
    );
    conn = HerdrConnection(
      profile,
      knownFingerprint: (h) => pinned[h],
      onNewHost: (h, f) async {
        pinned[h] = f;
        return true;
      },
    );
    await conn.connect(secret: keyFile.readAsStringSync());
  });

  tearDownAll(() async {
    if (keyFile.existsSync()) await conn.close();
  });


  test('pins the host key on first connect', () {
    expect(pinned['127.0.0.1:2222'], isNotNull);
    expect(pinned['127.0.0.1:2222']!.length, greaterThan(20));
  }, skip: missing ? 'test sshd not running' : null);

  // The reason this matters: a non-interactive SSH session gets
  // PATH=/usr/local/bin:/usr/bin, so a herdr in ~/.local/bin is invisible.
  test('finds herdr even though it is not on the SSH PATH', () async {
    final bare = Profile(
      id: 'bare',
      name: 'bare',
      host: '127.0.0.1',
      port: 2222,
      username: Platform.environment['USER'] ?? 'runner',
      // Deliberately the bare name, as a user would first configure it.
    );
    final c = HerdrConnection(
      bare,
      knownFingerprint: (h) => pinned[h],
      onNewHost: (h, f) async => true,
    );
    await c.connect(secret: keyFile.readAsStringSync());
    expect(c.herdrPath, startsWith('/'));
    expect(c.herdrPath, endsWith('/herdr'));
    // And it is actually usable, not just a plausible-looking string.
    expect(await c.version(), contains('herdr'));
    await c.close();
  }, skip: missing ? 'test sshd not running' : null);

  test('reads the herdr version', () async {
    final v = await conn.version();
    expect(v, contains('herdr'));
  }, skip: missing ? 'test sshd not running' : null);

  test('lists real sessions', () async {
    final sessions = await conn.sessions();
    expect(sessions, isNotEmpty);
    expect(sessions.any((s) => s.isDefault), isTrue);
  }, skip: missing ? 'test sshd not running' : null);

  test('parses the live agent snapshot', () async {
    profile.sessionName = 'default';
    final agents = await conn.agents();
    // The dev box always has at least one agent running under herdr.
    expect(agents, isNotEmpty);
    for (final a in agents) {
      expect(a.paneId, matches(RegExp(r'^w\d+:p\d+$')));
      expect(a.workspaceId, isNotEmpty);
    }
    // Blocked agents must sort ahead of everything else.
    final keys = agents.map(agentSortKey).toList();
    expect(keys, orderedEquals(List.of(keys)..sort()));
  }, skip: missing ? 'test sshd not running' : null);

  test('reads a pane as raw ANSI', () async {
    profile.sessionName = 'default';
    final agents = await conn.agents();
    final text = await conn.readAgent(agents.first.paneId, lines: 20);
    expect(text, isNotEmpty);
    // The whole terminal design rests on this being ANSI, not JSON.
    expect(text, contains('\x1b['));
    expect(text.trimLeft().startsWith('{'), isFalse);
  }, skip: missing ? 'test sshd not running' : null);

  test('surfaces a herdr error instead of hanging', () async {
    profile.sessionName = 'default';
    await expectLater(
      conn.readAgent('w99:p99'),
      throwsA(isA<HerdrException>()),
    );
  }, skip: missing ? 'test sshd not running' : null);

  test('reports a missing herdr binary distinctly', () async {
    final bad = Profile(
      id: 'bad',
      name: 'bad',
      host: '127.0.0.1',
      port: 2222,
      username: profile.username,
      herdrPath: '/nonexistent/herdr',
    );
    final c = HerdrConnection(
      bad,
      knownFingerprint: (h) => pinned[h],
      onNewHost: (h, f) async => true,
    );
    await c.connect(secret: keyFile.readAsStringSync());
    await expectLater(c.sessions(), throwsA(isA<HerdrNotFoundException>()));
    await c.close();
  }, skip: missing ? 'test sshd not running' : null);

  test('uploads an image over sftp and returns a usable path', () async {
    final bytes = await File(
      '${Directory.current.path}/test/fixtures/pixel.png',
    ).readAsBytes();
    final path = await conn.uploadImage('shot.png', bytes);
    expect(path, contains('.herdr-mobile/uploads'));
    expect(path, endsWith('-shot.png'));
    expect(File(path).existsSync(), isTrue);
    expect(File(path).lengthSync(), bytes.length);
    File(path).deleteSync();
  }, skip: missing ? 'test sshd not running' : null);

  test('a rejected host key aborts the connection', () async {
    final c = HerdrConnection(
      profile,
      knownFingerprint: (h) => 'definitely-not-the-real-fingerprint',
      onNewHost: (h, f) async => true,
    );
    await expectLater(
      c.connect(secret: keyFile.readAsStringSync()),
      throwsA(isA<HostKeyChangedException>()),
    );
  }, skip: missing ? 'test sshd not running' : null);
}
