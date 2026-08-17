import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/herdr.dart';
import 'package:herdr_mobile/keys.dart';
import 'package:herdr_mobile/models.dart';

void main() {
  group('shell quoting', () {
    test('wraps plainly', () {
      expect(shq('hello'), "'hello'");
    });

    test('neutralises embedded single quotes', () {
      expect(shq("it's"), r"'it'\''s'");
    });

    // The prompt path carries arbitrary user text to a shell — a quote that
    // escapes here is command injection on the user's own dev box.
    test('a crafted prompt cannot break out', () {
      const evil = "hi'; rm -rf ~; echo '";
      final quoted = shq(evil);
      expect(quoted.startsWith("'"), isTrue);
      expect(quoted.endsWith("'"), isTrue);
      // Every bare quote in the payload became the '\'' escape sequence.
      expect(RegExp(r"(?<!\\)'").allMatches(quoted).length, 2 + 2 * 2);
    });

    test('newlines survive intact', () {
      expect(shq('a\nb'), "'a\nb'");
    });
  });

  group('snapshot parsing', () {
    // Captured verbatim from `herdr api snapshot` on herdr 0.8.0.
    const raw = '''
{"agent":"claude","agent_status":"working","cwd":"/home/v/Projects/Strix",
 "focused":false,"foreground_cwd":"/home/v/Projects/Strix/.claude/worktrees/wt",
 "pane_id":"w3:p2","revision":5600,"state_change_seq":128,"tab_id":"w3:t2",
 "terminal_title":"\\u25d1 Create separate worktree","workspace_id":"w3",
 "terminal_title_stripped":"Create separate worktree"}''';

    test('reads the fields the UI shows', () {
      final a = AgentInfo.fromJson(
          jsonDecode(raw.replaceAll('\n', '')) as Map<String, dynamic>);
      expect(a.agent, 'claude');
      expect(a.status, AgentStatus.working);
      expect(a.paneId, 'w3:p2');
      expect(a.workspaceId, 'w3');
      expect(a.revision, 5600);
      // Prefers the stripped title so the spinner glyph never reaches the card.
      expect(a.title, 'Create separate worktree');
      // Repo label follows the foreground cwd, which is the worktree.
      expect(a.repo, 'wt');
    });

    test('falls back to the raw title when no stripped one is sent', () {
      final a = AgentInfo.fromJson({
        'agent': 'codex',
        'agent_status': 'blocked',
        'terminal_title': ' Waiting ',
      });
      expect(a.title, 'Waiting');
      expect(a.status, AgentStatus.blocked);
    });

    test('an unrecognised status degrades instead of throwing', () {
      final a = AgentInfo.fromJson({'agent_status': 'brand_new_state'});
      expect(a.status, AgentStatus.unknown);
      expect(a.agent, 'agent');
    });

    test('empty json yields a usable object', () {
      final a = AgentInfo.fromJson({});
      expect(a.status, AgentStatus.unknown);
      expect(a.paneId, '');
      expect(a.repo, '');
    });
  });

  group('agent ordering', () {
    test('blocked sorts above everything', () {
      AgentInfo mk(String n, AgentStatus s) => AgentInfo(
            agent: n,
            status: s,
            cwd: '',
            foregroundCwd: '',
            paneId: n,
            tabId: '',
            workspaceId: 'w1',
            title: '',
            focused: false,
            revision: 0,
            stateChangeSeq: 0,
          );
      final list = [
        mk('idle', AgentStatus.idle),
        mk('unknown', AgentStatus.unknown),
        mk('blocked', AgentStatus.blocked),
        mk('working', AgentStatus.working),
        mk('done', AgentStatus.done),
      ]..sort((a, b) => agentSortKey(a).compareTo(agentSortKey(b)));
      expect(list.map((a) => a.agent).toList(),
          ['blocked', 'done', 'working', 'idle', 'unknown']);
    });
  });

  group('key tokens', () {
    test('modifiers serialise in a fixed order', () {
      expect(keyToken('c', {'alt', 'ctrl'}), 'ctrl+alt+c');
      expect(keyToken('c', {'ctrl', 'alt'}), 'ctrl+alt+c');
    });

    test('bare keys pass through', () {
      expect(keyToken('esc', {}), 'esc');
    });

    test('herdr spellings are the ones we send', () {
      // herdr uses pgup/pgdn, not pageup/pagedown, and esc, not escape.
      expect(isValidKeyToken('pgup'), isTrue);
      expect(isValidKeyToken('pgdn'), isTrue);
      expect(isValidKeyToken('esc'), isTrue);
      expect(isValidKeyToken('pageup'), isFalse);
    });

    test('rejects unknown modifiers and duplicates', () {
      expect(isValidKeyToken('hyper+c'), isFalse);
      expect(isValidKeyToken('ctrl+ctrl+c'), isFalse);
    });

    test('accepts single printable characters', () {
      expect(isValidKeyToken('ctrl+c'), isTrue);
      expect(isValidKeyToken('a'), isTrue);
      expect(isValidKeyToken('nonsense'), isFalse);
    });
  });

  group('pty key encoding', () {
    // Attached to the herdr TUI these go down the PTY; send-keys would target
    // the agent pane instead, where page keys do nothing.
    test('page keys encode so they can scroll', () {
      expect(keyBytes('pgup', {}), '\x1b[5~');
      expect(keyBytes('pgdn', {}), '\x1b[6~');
    });

    test('arrows and esc encode', () {
      expect(keyBytes('up', {}), '\x1b[A');
      expect(keyBytes('down', {}), '\x1b[B');
      expect(keyBytes('esc', {}), '\x1b');
      expect(keyBytes('enter', {}), '\r');
    });

    test('ctrl masks the low five bits', () {
      expect(keyBytes('c', {'ctrl'}), '\x03');
      expect(keyBytes('a', {'ctrl'}), '\x01');
      expect(keyBytes('C', {'ctrl'}), '\x03');
    });

    test('alt prefixes escape', () {
      expect(keyBytes('b', {'alt'}), '\x1bb');
      expect(keyBytes('up', {'alt'}), '\x1b\x1b[A');
    });

    test('unknown keys return null rather than sending garbage', () {
      expect(keyBytes('nonsense', {}), isNull);
    });
  });

  group('profile round-trip', () {
    test('survives json without losing forwards', () {
      final p = Profile(
        id: '1',
        name: 'box',
        host: 'h',
        username: 'u',
        forwards: [ForwardRule(id: 'f1', port: 3000)],
      );
      final back = Profile.fromJson(p.toJson());
      expect(back.name, 'box');
      expect(back.forwards.single.port, 3000);
      expect(back.forwards.single.url, 'http://localhost:3000');
      expect(back.target, 'u@h');
    });

    test('a non-default port shows in the target', () {
      final p = Profile(
          id: '1', name: 'b', host: 'h', username: 'u', port: 2222);
      expect(p.target, 'u@h:2222');
    });

    test('forward rules saved in the old two-port form still load', () {
      final r = ForwardRule.fromJson({
        'id': 'f1',
        'localPort': 8080,
        'remoteHost': '127.0.0.1',
        'remotePort': 8080,
        'autoStart': true,
      });
      expect(r.port, 8080);
      expect(r.autoStart, isTrue);
    });

    test('unknown fields in stored json do not break loading', () {
      final back = Profile.fromJson({
        'id': '1',
        'name': 'b',
        'host': 'h',
        'username': 'u',
        'somethingNew': 42,
      });
      expect(back.port, 22);
      expect(back.herdrPath, 'herdr');
      expect(back.pollMs, 2000);
    });
  });
}
