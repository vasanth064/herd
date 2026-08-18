import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/herdr.dart';

void main() {
  test('reduces a rendered permission prompt to its question', () {
    const raw = '\x1b[0m\x1b[38;2;136;136;136m'
        '╭──────────────────────────────╮\x1b[0m\r\n'
        '│ \x1b[1mBash command\x1b[0m         │\r\n'
        '│ rm -rf build/                │\r\n'
        '│                              │\r\n'
        '│ Do you want to proceed?      │\r\n'
        '│ ❯ 1. Yes                     │\r\n'
        '│   2. Yes, and don\'t ask      │\r\n'
        '│   3. No                      │\r\n'
        '╰──────────────────────────────╯\r\n';

    final out = HerdrConnection.plainText(raw);
    expect(out, contains('Do you want to proceed?'));
    expect(out, contains('1. Yes'));
    expect(out, contains('3. No'));
    // The frame and the escapes must be gone, or the notification is line art.
    expect(out, isNot(contains('\x1b')));
    expect(out, isNot(contains('─')));
    expect(out, isNot(contains('╭')));
  });

  test('keeps only the tail, since a pane read is mostly scrollback', () {
    final raw = List.generate(40, (i) => 'line $i').join('\n');
    final out = HerdrConnection.plainText(raw, keepLines: 3);
    expect(out, 'line 37\nline 38\nline 39');
  });

  test('reports nothing rather than whitespace for an empty pane', () {
    expect(HerdrConnection.plainText('\x1b[0m\r\n   \r\n'), isEmpty);
  });
}
