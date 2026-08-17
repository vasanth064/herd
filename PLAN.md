# Herdr Mobile — Implementation Plan

Flutter (Android-first) client for driving `herdr` — the terminal workspace
manager for AI coding agents already installed on this machine — over SSH.

Status: **built**. All 21 functional requirements in §4 are implemented.
`flutter analyze` clean; 41 tests pass (17 unit, 15 widget, 9 integration
against the live local herdr). Debug and obfuscated release APKs both build.

Not yet done: run on a physical Android device. Nothing here has been executed
on real hardware — no device is attached to this machine and an emulator did
not fit in RAM. `adb` is installed, so:

```
flutter devices                 # with the phone plugged in, USB debugging on
flutter run --release
```

Building the release APK for sideloading instead:

```
flutter build apk --release --split-per-abi \
  --obfuscate --split-debug-info=build/symbols
```

`--split-per-abi` matters: the fat APK is 54.8 MB, the per-ABI ones ~18 MB.

---

## 1. What this is

`herdr` v0.8.0 runs a headless server on the dev box with a Unix-socket API
(protocol 19, 90 methods) and a CLI in front of it. It already knows which
panes hold coding agents, what each one is doing, and whether it is `idle`,
`working`, `blocked`, `done`, or `unknown`.

A live snapshot looks like this:

```json
{"agent":"claude","agent_status":"working","cwd":"/home/vasanth/Projects/Strix",
 "pane_id":"w3:p2","tab_id":"w3:t2","workspace_id":"w3","focused":false,
 "terminal_title":"◑ Create separate worktree for changes"}
```

So the app writes no agent-detection, no tmux parsing, no protocol of its own.
It is a **mobile front-end for an API that already exists**. The phone's job:
show that list, let you open one, read it, type into it, and hand it a photo.

Not building: a companion daemon, a tmux client, voice dictation, theming
beyond dark/light, an iOS build (no Mac), auth/accounts, telemetry.

---

## 2. Architecture

```
Flutter app ──SSH (dartssh2)──> dev box ──> herdr CLI ──> herdr.sock ──> agents
```

One `SSHClient` per connected profile, multiplexing three channel kinds:

| Channel | Lifetime | Purpose |
|---|---|---|
| exec | per call | `herdr api snapshot`, `session list`, `agent read`, `agent prompt`, `agent send-keys` |
| SFTP | per upload | push an image to the box |
| shell (PTY) | only if `agent attach` is adopted later (§2) | live agent view |

Plus `forwardLocal()` for port forwarding, on the same connection.

**State updates: poll `herdr api snapshot` every 2s while foregrounded.**
Cheap (one exec channel on an already-open connection), no new server code.

> Ceiling: 2s lag on status chips, and a poll per profile.
> Upgrade path when it bites: `herdr` exposes `events.subscribe` on the socket.
> Open one long-lived exec channel running
> `socat - UNIX-CONNECT:$HOME/.config/herdr/herdr.sock`, speak the JSON protocol
> directly, and consume `subscription_event` frames as a push stream. Costs a
> `socat` dependency on the host, so it is not the starting point.

### Why not attach the TUI

Running `herdr` bare in a PTY renders the full desktop TUI — sidebars, tab
chrome, multi-pane layout — inside a 6" screen. The whole point of the socket
API is that a client can present the same state in a form that suits its
screen. Terminal rendering is used for **one agent at a time**, full-bleed.

### Terminal rendering: settled — read-and-repaint

Verified against the live local herdr:

```
herdr agent read w3:p2 --source recent-unwrapped --lines 6 --format ansi
```

returns **raw ANSI bytes on stdout** — not JSON, not escaped. 24-bit colour
(`ESC[38;2;136;136;136m`), real rendered content. That goes straight into
`terminal.write()` with no parsing on our side.

So the design is: poll `agent read --source recent-unwrapped --format ansi
--lines N` and repaint the `Terminal`. Input goes back through `agent prompt`
and `agent send-keys`. Nothing else is needed for a working terminal view.

`recent-unwrapped` is the right source specifically because it joins soft
wraps — the pane is sized by the desktop client (~120 cols) and a phone is not.
Unwrapped text lets `xterm` re-wrap at the phone's width instead of inheriting
a desktop-width grid and wrapping twice. `visible` would hand us the desktop
geometry and look broken.

This is a repaint model, not an append stream: each poll replaces the view. It
costs live cursor motion and per-keystroke echo, and it cannot recover rows that
scrolled off an alternate screen (herdr's own docs call that out). It buys a
view that always works and never fights the desktop client.

> Possible upgrade: `herdr agent attach <target>` in a PTY, for true live
> interactivity. Not the starting point — `attach` takes `--takeover`, meaning
> it contends with the desktop TUI for the same pane, and herdr's guidance is
> explicit about not stealing another client's focus. Revisit only if the
> repaint model proves too coarse in daily use.

Either way the bytes land in the same `Terminal` object, so this is one class
behind an interface and does not move the UI.

### Input path (matters more than it looks)

- **Prompt bar text → `herdr agent prompt <target> <text>`.** Atomic; herdr
  handles the pane's live bracketed-paste mode and the encoded Enter itself.
  Sending the text character-by-character through the PTY makes agent TUIs run
  autocomplete per keystroke and mangles multi-line input.
- **Key row / soft keyboard → `herdr agent send-keys <target> <key>`**, using
  herdr's logical key names (`esc`, `ctrl+c`, `up`, `pgup`). herdr validates
  every key before writing any bytes, so a bad mapping fails loudly instead of
  injecting garbage into a running agent.

### Packages

| Need | Package | Version checked |
|---|---|---|
| SSH, PTY, SFTP, port forwarding | `dartssh2` | 2.22.5 |
| Terminal emulation + widget | `xterm` | 4.0.0 |
| Keys/passwords at rest | `flutter_secure_storage` | **pinned ^10** — see below |
| Profiles, forward rules, prefs | `shared_preferences` | JSON blob |
| Image picking | `image_picker` | |
| Private key import | `file_picker` | |
| Open forwarded port | `url_launcher` | |

State: `ValueNotifier`/`ChangeNotifier` + `provider`. No Bloc, no Riverpod, no
code generation — this app has one connection object and one snapshot stream.

**Do not bump `flutter_secure_storage` to 11.** v11 requires `compileSdk 37`,
and Google's current `cmdline-tools` (22.0, the latest published) cannot install
that platform correctly — it misreads the v4 repository XML and writes a
corrupt `platforms/android-37.0` with `ApiLevel=37.0` and
`Pkg.Desc=Android SDK Platform 17`, which Gradle then fails to resolve. v10.3.1
targets `compileSdk 36`, keeps `encryptedSharedPreferences: true`, and builds.
Revisit when cmdline-tools ships XML v4 support.

---

## 3. Screens & UX

Dark by default. Monospace everywhere that shows machine output. Designed
one-handed: primary actions in the bottom third.

### 3.1 Profiles — launch screen

- List of saved SSH profiles. Each row: name, `user@host:port`, connection dot
  (grey disconnected / amber connecting / green connected), and a live count
  badge — "3 working · 1 blocked" — once connected.
- Tap = connect and push to Agents. Long-press = edit / duplicate / delete.
- FAB: add profile.
- Empty state explains the one prerequisite: `herdr` on the box's `PATH`.

### 3.2 Profile editor

Name · Host · Port (22) · Username · Auth method:
- **Private key** (default) — import via file picker, optional passphrase
- **Password**

Advanced (collapsed): herdr binary path (default `herdr`), keepalive interval,
poll interval, port-forward rules.

"Test connection" runs `herdr status` and reports one of: reachable + herdr
version, reachable but herdr missing, or the SSH error. Fingerprint is shown
and accepted on first connect.

### 3.3 Sessions — shown only when there is a choice

`herdr session list --json` returns every named session on the host:

```json
{"sessions":[{"name":"default","default":true,"running":true,
              "socket_path":"/home/vasanth/.config/herdr/herdr.sock"}]}
```

Every subsequent command is scoped with the global flag — verified:
`herdr --session <name> agent list`.

On this box there is exactly one session, so **the picker is skipped whenever
`sessions.length == 1`** and the app goes straight to Agents. With two or more,
a bottom sheet lists them (name, running/stopped, agent count) — the equivalent
of the screenshot's session picker. The chosen session is remembered per
profile and shown in the Agents app bar; switching is one tap from the overflow
menu. Stopped sessions are listed and greyed, not hidden, so a missing session
is legible rather than mysterious.

### 3.4 Agents — the home screen

The screen that justifies the app. Built from `session.snapshot`.

```
┌────────────────────────────────────────┐
│ ‹  hetzner-01          ⟳ 2s      ⋮     │
│ [All] [Blocked 1] [Working 3] [Idle 2] │
├────────────────────────────────────────┤
│ ▌🔴 reviewer            blocked   ⌁    │  ← pinned, needs you
│ ▌  ◍ Approve edit to routes.ts         │
│ ▌  Strix · w3:p2                       │
├────────────────────────────────────────┤
│   🟡 claude             working        │
│      ◑ Create separate worktree for…   │
│      Strix · w3:p2              4m     │
├────────────────────────────────────────┤
│   🟢 codex              idle           │
│      Redesign dashboard UI with charts │
│      insights-redesign · w3:p3         │
└────────────────────────────────────────┘
```

- **`blocked` sorts to the top with a left accent bar.** A blocked agent is the
  only thing on this screen that is costing you time.
- Second line is `terminal_title` — herdr already puts the agent's current task
  there. It reads as an activity feed for free.
- Third line: cwd basename (the repo/worktree you actually think in) + pane id.
- Grouped by workspace with sticky headers when more than one workspace exists.
- Pull-to-refresh forces a snapshot. `⟳ 2s` shows poll freshness; it goes red
  and reads `stale` if a poll fails.
- Overflow menu: port forwards, settings, disconnect.

### 3.5 Terminal — one agent, full-bleed

```
┌────────────────────────────────────────┐
│ ‹ 🟡 claude  Strix        A- A+  ⋮     │
│ ● claude   │ ○ codex   │ ○ reviewer   │  ← workspace agents, one tap
├────────────────────────────────────────┤
│                                        │
│            xterm TerminalView          │
│         (scroll, select, pinch)        │
│                                        │
├────────────────────────────────────────┤
│ 🖼  ⌨  › type a prompt…          ➤    │
├────────────────────────────────────────┤
│ ESC TAB CTRL ALT ↑ ↓ ← → pgUp pgDn ⌫ ⏎ │  ← scrollable, above soft kbd
└────────────────────────────────────────┘
```

- **Tab strip** = the other agents in this workspace, from the same snapshot.
  Dot colour carries live status, so you see a sibling go `blocked` without
  leaving the pane you're in. No close or add buttons in v1 — the app drives
  agents, it does not create or kill them (open question 2).
- **Prompt bar** is the default input, not the terminal itself. Multi-line
  capable (grows to 4 lines). Send goes through `agent prompt`.
- **Key row** is horizontally scrollable and sits directly above the soft
  keyboard when it opens (`viewInsets`-aware, never covered). Sticky modifiers:
  CTRL/ALT latch for one keypress and show a lit state.
- **Image button** → pick from gallery or camera → SFTP upload to
  `~/.herdr-mobile/uploads/<epoch>-<name>.png` → insert the **remote path** into
  the prompt bar, cursor after it. Not auto-sent: you almost always want to type
  "the deploy button overflows here" next to it. An inline chip shows the
  thumbnail and upload progress; failure leaves the text untouched.
- Status dot in the app bar mirrors the agent's lifecycle. When it flips to
  `blocked` a subtle banner offers "jump to prompt".
- Font size A-/A+ persists per profile.
- Long-press a region → copy. Double-tap a word → select.

### 3.6 Port forwards

Per profile: rules of the form `localhost:3000 → 127.0.0.1:3000`, each with a
toggle and a live/failed indicator. An "open" button launches
`http://127.0.0.1:<local>` in the phone browser — which is the actual reason
this feature exists: run the dev server on the box, look at it on the phone.
Rules marked auto-start come up with the connection.

### 3.7 Settings

Font size default, theme (dark/light/system), poll interval (1/2/5s), scrollback
line cap, "forget host key" per host, clear uploaded images on the remote.

---

## 4. Functional requirements

**Profiles**
1. Create, edit, duplicate, delete SSH profiles; persist across launches.
2. Auth by imported private key (with optional passphrase) or password.
3. Secrets stored only in `flutter_secure_storage`; never in prefs, never logged.
4. Test-connection reports SSH reachability and herdr presence/version separately.

**Connection**
5. Connect/disconnect per profile; at most one active connection in v1.
6. Verify the host key on first connect (trust-on-first-use), store the
   fingerprint, and **block with a visible warning if it ever changes**.
7. Reconnect automatically on `AppLifecycleState.resumed` and on network
   regain, with exponential backoff (1s → 30s cap) and a visible state.
8. Surface connection errors in plain language, distinguishing auth failure,
   host unreachable, and herdr-not-found.

**Sessions & agents**
9. List sessions via `herdr session list`; auto-select when there is only one,
   otherwise let the user pick, and scope every later call with
   `herdr --session <name>`.
10. List every agent from `herdr api snapshot` with kind, name, status, title,
    cwd, workspace/tab/pane ids. Show `terminal_title_stripped` (herdr
    pre-strips the spinner glyph) and drive the activity animation off the raw
    `terminal_title`.
11. Refresh every N seconds while foregrounded; suspend polling in background.
12. Sort `blocked` first; filter by status; group by workspace.
13. Open an agent into the terminal view.

**Terminal**
14. Render agent output with ANSI colour and styling into `xterm`.
15. Send prompt text via `herdr agent prompt`, preserving multi-line input.
16. Send control keys (ESC, TAB, CTRL+x, ALT+x, arrows, page up/down, Enter,
    backspace) from the key row and from the soft keyboard.
17. Scroll back through history by touch; pinch or A-/A+ to change font size.
18. Switch between agents in the workspace from the tab strip.
19. Select and copy text out of the terminal.

**Images**
20. Pick from gallery or camera, upload over SFTP, insert the remote path into
    the prompt bar; show progress and handle failure without losing typed text.

**Port forwarding**
21. Define, persist, toggle, and auto-start local→remote forward rules per
    profile; open a forwarded port in the phone browser.

---

## 5. Non-functional requirements

**Security**
- Private keys, passphrases, and passwords in Android Keystore only.
- No credential, key material, or full pane content in logs or crash output.
- Host key TOFU with hard block on mismatch — no "accept anyway" on the happy
  path; changing a stored fingerprint takes a deliberate trip to settings.
- Uploaded images land in a dedicated `~/.herdr-mobile/uploads/` directory,
  `0700`, so cleanup is one action and nothing else is touched.
- `flutter build apk --obfuscate --split-debug-info`.

**Reliability**
- Android will kill the socket in the background. Reattachment on resume is a
  core mechanism, not polish: herdr holds all session state server-side, so
  reconnect + re-open the pane must land the user exactly where they were.
- A failed poll degrades to a `stale` badge; it never clears the agent list.
- No action silently no-ops: every `agent prompt` / `send-keys` reports failure.

**Performance**
- Scrollback capped (default 5000 lines) to bound memory.
- Terminal writes batched per frame; no rebuild of the agent list when the
  snapshot is byte-identical (compare `revision`/`state_change_seq`).
- Polling and PTY reads stop entirely when backgrounded.
- Cold start to profile list under 1s on mid-range hardware.

**Usability / accessibility**
- Every tap target ≥ 44dp; key-row keys ≥ 40dp wide with real spacing.
- Status is never colour-only — each chip carries a text label and a distinct
  glyph, so it survives colour-blindness and greyscale.
- Semantic labels on status chips and key-row keys for TalkBack.
- Terminal text respects the A-/A+ setting rather than the system font scale
  (scaling a monospace grid by system settings breaks alignment).
- Key row and prompt bar always clear the soft keyboard inset.

**Portability**
- Pure-Dart dependencies only; no platform channels of our own. An iOS build is
  then a build, not a port.

---

## 6. Data model

```dart
class Profile {
  String id, name, host, username;
  int port;                       // 22
  AuthMethod auth;                // key | password
  String? keyId;                  // secure-storage handle, never the key
  String herdrPath;               // 'herdr'
  int pollMs;                     // 2000
  List<ForwardRule> forwards;
  double fontSize;
}

class ForwardRule {
  String id; int localPort; String remoteHost; int remotePort;
  bool autoStart; bool active;
}

class KnownHost { String hostPort, fingerprint; DateTime firstSeen; }

class AgentInfo {                 // parsed from session.snapshot
  String agent, agentStatus, cwd, foregroundCwd;
  String paneId, tabId, workspaceId, terminalTitle;
  bool focused; int revision, stateChangeSeq;
}
```

Profiles and rules → `shared_preferences` as one JSON blob. Keys, passphrases,
passwords → `flutter_secure_storage`. Nothing else persists.

---

## 7. Milestones

| # | Deliverable | Done when |
|---|---|---|
| M0 | Toolchain + scaffold | `flutter doctor` clean for Android; app runs on device |
| M1 | Profiles + connect | Save a profile, connect, `herdr status` round-trips; TOFU host key stored |
| M2 | Terminal view | `agent read --format ansi` piped into `xterm`; one agent renders in colour, re-wrapped to phone width |
| M3 | Agents screen | Live list, status chips, blocked-first, filters, poll + stale badge |
| M4 | Input | Prompt bar via `agent prompt`, key row, soft keyboard, tab strip |
| M5 | Images | Pick → SFTP → path inserted, with progress and failure handling |
| M6 | Forwards + resume | Rules toggle, open-in-browser, reconnect-on-resume verified by airplane-mode toggle |

No milestone is gated on an unknown: the read format, the `--session` flag, and
the snapshot shape were each verified against the running herdr before this plan
was finalised. M1 is the first real risk — SSH auth against a real device.

---

## 8. Testing

- Unit (`test/widget_test.dart`, 17 tests): snapshot JSON → `AgentInfo`
  including unknown statuses and missing titles; shell quoting against a
  crafted injection payload; key-token spelling and validation; blocked-first
  ordering; profile round-trip with unknown stored fields.
- Integration (`test/integration_test.dart`, 9 tests, tagged `integration`):
  drives the real stack — dartssh2 → sshd → herdr CLI → herdr server — against
  the live local herdr. Read-only except for one SFTP upload it deletes again.

  ```
  bash test/integration_setup.sh up
  flutter test test/integration_test.dart --tags integration
  bash test/integration_setup.sh down
  ```

  `integration_setup.sh` starts a throwaway sshd on `127.0.0.1:2222` with its
  own host key and authorized_keys under `/tmp/herdr-itest`. It never touches
  `~/.ssh/authorized_keys` or the system sshd. The test skips itself when that
  sshd is absent, so `flutter test` stays green anywhere.

**Two bugs this caught that unit tests could not:**

1. herdr reports errors as a JSON envelope on stderr, and `agent_not_found`
   carries the words "not found". A substring check meant a typo'd pane id was
   reported to the user as "herdr is not on your PATH". Now the envelope is
   parsed first; only exit 127 or a shell-level message means a missing binary.
2. Throwing `HostKeyChangedException` from inside dartssh2's `onVerifyHostKey`
   does not propagate — the transport just closes and the caller sees
   "Connection closed before authentication". A swapped host key was therefore
   indistinguishable from a network blip. The callback now records the mismatch
   and returns false, and `connect()` raises the real exception afterwards.
- Manual matrix: airplane-mode toggle mid-session, app backgrounded 10min,
  wrong password, host key changed, herdr not installed, herdr server stopped.

---

## 9. Risks

| Risk | Response |
|---|---|
| Repaint model feels coarse next to a live terminal | `agent attach` in a PTY is the upgrade path (§2); the view layer does not change |
| Desktop-width panes wrap badly on a phone | `recent-unwrapped` + xterm re-wrap — precisely what that source exists for |
| Snapshot poll too laggy in practice | `events.subscribe` via socat, section 2 |
| herdr protocol 19 changes under us | Parse defensively; `herdr status` reports protocol, warn on mismatch rather than crash |
| `xterm` 4.0.0 is two years old | It only needs a byte stream; if the widget API drifted, swapping the view layer does not touch the transport |
| Java 25 vs Gradle | Portable JDK 21 installed alongside and pinned via `flutter config --jdk-dir` |

---

## 10. Open questions

1. Multiple simultaneous profile connections, or one at a time? Plan assumes one.
2. Should the app be able to *start* agents (`herdr agent start`) and split
   panes, or only drive existing ones? Plan assumes drive-only for v1.
3. Push notification when an agent goes `blocked` — genuinely useful, but needs
   a background service and a wake strategy. Out of v1; worth its own round.
