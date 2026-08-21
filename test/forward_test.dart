import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/herdr.dart';
import 'package:herdr_mobile/models.dart';

HerdrConnection _conn() => HerdrConnection(
      Profile(id: 'p', name: 'p', host: '127.0.0.1', username: 'u'),
      knownFingerprint: (_) => null,
      onNewHost: (_, _) async => true,
    );

void main() {
  // Reconnecting used to drop the old connection without closing it, leaving
  // its listener bound; every auto-started forward then failed to bind.
  test('closing a connection frees its forwarded ports', () async {
    final rule = ForwardRule(id: 'f', port: 47823);
    final first = _conn();
    await first.startForward(rule);
    expect(first.forwardActive(rule), isTrue);

    final second = _conn();
    await expectLater(second.startForward(rule), throwsA(isA<SocketException>()));

    await first.close();
    await second.startForward(rule);
    expect(second.forwardActive(rule), isTrue);
    await second.close();
  });

  test('a prohibited channel is permanent, a closed port is not', () {
    expect(isForwardingRefused(SSHChannelOpenError(1, 'administratively '
        'prohibited: port forwarding is disabled')), isTrue);
    expect(isForwardingRefused(SSHChannelOpenError(2, 'connect failed')),
        isFalse);
    expect(forwardFailure(SSHChannelOpenError(1, 'nope')),
        contains('Tailscale SSH'));
    expect(forwardFailure(SSHChannelOpenError(2, 'connect failed')),
        'connect failed');
  });
}
