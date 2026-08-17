/// Key names accepted by `herdr agent send-keys`, taken from herdr's own
/// vocabulary (`esc` is canonical; page keys are `pgup`/`pgdn`, not `pageup`).
const herdrKeyNames = {
  'esc', 'tab', 'backtab', 'enter', 'backspace', 'delete', 'insert', //
  'up', 'down', 'left', 'right', 'home', 'end', 'pgup', 'pgdn', 'space',
  'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9', 'f10', 'f11', 'f12',
};

const herdrModifiers = {'ctrl', 'alt', 'shift', 'super'};

/// Builds a `send-keys` token, e.g. ('c', {'ctrl'}) -> 'ctrl+c'.
/// Modifiers are emitted in a fixed order so the same combo always
/// serialises identically.
String keyToken(String key, Set<String> modifiers) {
  const order = ['ctrl', 'alt', 'shift', 'super'];
  final mods = order.where(modifiers.contains);
  return [...mods, key].join('+');
}

const _sequences = {
  'esc': '\x1b',
  'tab': '\t',
  'backtab': '\x1b[Z',
  'enter': '\r',
  'backspace': '\x7f',
  'delete': '\x1b[3~',
  'insert': '\x1b[2~',
  'up': '\x1b[A',
  'down': '\x1b[B',
  'right': '\x1b[C',
  'left': '\x1b[D',
  'home': '\x1b[H',
  'end': '\x1b[F',
  'pgup': '\x1b[5~',
  'pgdn': '\x1b[6~',
  'space': ' ',
};

/// Bytes for a key when writing straight to a PTY.
///
/// Needed because `herdr agent send-keys` targets the agent's pane, so while
/// the herdr TUI itself is attached those keys never reach it — pgup/pgdn
/// would not scroll. Returns null when the key has no encoding.
String? keyBytes(String key, Set<String> modifiers) {
  final ctrl = modifiers.contains('ctrl');
  final alt = modifiers.contains('alt');

  String? base;
  if (ctrl && key.length == 1) {
    // Ctrl masks the low 5 bits: 'a' -> 0x01, '[' -> 0x1b.
    final c = key.toLowerCase().codeUnitAt(0);
    base = String.fromCharCode(c & 0x1f);
  } else {
    base = _sequences[key];
    if (base == null && key.length == 1) {
      base = modifiers.contains('shift') ? key.toUpperCase() : key;
    }
  }
  if (base == null) return null;
  return alt ? '\x1b$base' : base;
}

/// True when herdr will accept this token. herdr validates before writing any
/// bytes, so a rejected token is safe — but catching it here gives a better
/// message than a round trip.
bool isValidKeyToken(String token) {
  final parts = token.split('+');
  if (parts.isEmpty) return false;
  final key = parts.removeLast();
  if (parts.any((m) => !herdrModifiers.contains(m))) return false;
  if (parts.toSet().length != parts.length) return false;
  if (herdrKeyNames.contains(key)) return true;
  return key.length == 1 && key.codeUnitAt(0) > 32 && key.codeUnitAt(0) < 127;
}
