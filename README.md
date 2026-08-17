# Herd

An Android app for driving [herdr](https://herdr.dev) agents from your phone.

herdr runs your coding agents (claude, codex, …) in terminal workspaces on a
dev machine and exposes them over a socket API. Herd connects to that machine
over SSH and gives you the parts that matter on a phone: which agents are
running, which one is blocked waiting on you, and a terminal to answer it in.

## What it does

- **Agent list** — every agent with its live status (`blocked`, `working`,
  `idle`, `done`) and the task it is currently on, grouped by workspace.
  Blocked agents sort to the top, because they are the ones costing you time.
- **Terminal** — attaches the herdr TUI over a PTY sized to your screen, so
  herdr lays the pane out for the phone rather than a 120-column desktop.
  Drag to scroll, one-tap key row, image upload.
- **Workspaces and tabs** — create, rename, close, and open them, including
  tabs running a plain shell with no agent.
- **Ports** — forward a port and open it in the phone's browser. A foreground
  service holds the tunnel open while you are in another app; Android freezes
  a backgrounded process within seconds and the forward would otherwise stop
  answering.
- **SSH profiles** — key or password, host keys pinned on first use.

## Requirements

- Android 6.0+
- A machine running `herdr`, reachable over SSH

## Setup

1. Add a host: name, address, username, and a private key.
2. Under **Advanced**, leave the herdr path as `herdr` — the app resolves the
   real path itself. A non-interactive SSH session gets a minimal `PATH`, so a
   herdr installed in `~/.local/bin` is invisible without this.
3. Connect. If the machine runs more than one herdr session you will be asked
   which; otherwise it goes straight to your agents.

## Building

```bash
flutter build apk --release --split-per-abi \
  --obfuscate --split-debug-info=build/symbols
```

## Tests

```bash
flutter test                       # unit + widget
```

Integration tests drive the real stack — dartssh2 → sshd → herdr — against a
local herdr. They stand up a throwaway sshd on `127.0.0.1:2222` with its own
key, so your own SSH configuration is never touched, and skip themselves when
it is not running:

```bash
bash test/integration_setup.sh up
flutter test test/integration_test.dart --tags integration
bash test/integration_setup.sh down
```

## Notes

`flutter_secure_storage` is pinned to `^10`. Version 11 requires
`compileSdk 37`, which Google's current `cmdline-tools` cannot install
correctly. See `PLAN.md`.

## License

MIT
