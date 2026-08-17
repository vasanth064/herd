#!/usr/bin/env bash
# Throwaway sshd on 127.0.0.1:2222 for the integration test.
# Isolated on purpose: never touches ~/.ssh/authorized_keys or system sshd.
set -euo pipefail
T=/tmp/herdr-itest

case "${1:-up}" in
up)
  rm -rf "$T"
  mkdir -p "$T"
  chmod 700 "$T"
  ssh-keygen -q -t ed25519 -f "$T/hostkey" -N '' -C testhost
  ssh-keygen -q -t ed25519 -f "$T/testkey" -N '' -C itest
  cp "$T/testkey.pub" "$T/authorized_keys"
  chmod 600 "$T/authorized_keys"
  SFTP=$(command -v sftp-server || echo /usr/libexec/openssh/sftp-server)
  cat > "$T/sshd_config" <<EOF
Port 2222
ListenAddress 127.0.0.1
HostKey $T/hostkey
AuthorizedKeysFile $T/authorized_keys
PasswordAuthentication no
UsePAM no
StrictModes no
PidFile $T/sshd.pid
Subsystem sftp $SFTP
EOF
  /usr/sbin/sshd -f "$T/sshd_config" -E "$T/sshd.log"
  sleep 1
  echo "test sshd up on 127.0.0.1:2222"
  ;;
down)
  [ -f "$T/sshd.pid" ] && kill "$(cat "$T/sshd.pid")" 2>/dev/null || true
  rm -rf "$T"
  echo "test sshd down"
  ;;
*)
  echo "usage: $0 up|down" >&2
  exit 2
  ;;
esac
