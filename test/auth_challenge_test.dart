import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/herdr.dart';

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
}
