import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/herdr.dart';
import 'package:herdr_mobile/models.dart';

HerdrConnection _conn(AuthMethod auth) => HerdrConnection(
      Profile(
        id: 'p',
        name: 'p',
        host: '127.0.0.1',
        port: 1,
        username: 'u',
        auth: auth,
      ),
      knownFingerprint: (_) => null,
      onNewHost: (_, _) async => true,
    );

void main() {
  // Tailscale SSH delivers its check as a keyboard-interactive request with no
  // prompts; the URL only exists in the instruction text.
  test('pulls the check URL out of a Tailscale challenge', () {
    const c = AuthChallenge(
      'Tailscale SSH',
      '# Tailscale SSH requires an additional check.\n'
          '# To authenticate, visit: https://login.tailscale.com/a/deadbeef\n',
      [],
    );
    expect(c.url, 'https://login.tailscale.com/a/deadbeef');
  });

  test('has no URL for an ordinary password challenge', () {
    const c = AuthChallenge('', 'Password: ', [('Password: ', false)]);
    expect(c.url, isNull);
    expect(c.prompts.single.$2, isFalse);
  });

  test('the check URL survives arriving as an auth banner', () {
    expect(
      firstUrl('# To authenticate, visit: https://login.tailscale.com/a/beef'),
      'https://login.tailscale.com/a/beef',
    );
    expect(firstUrl('Last login: Tue'), isNull);
  });

  // Tailscale hosts have no key to upload: the host authorises the device.
  test('only key auth insists on a stored private key', () async {
    await expectLater(
      _conn(AuthMethod.key).connect(),
      throwsA(isA<AuthException>()),
    );
    await expectLater(
      _conn(AuthMethod.tailscale).connect(),
      throwsA(isNot(isA<AuthException>())),
    );
  });
}
