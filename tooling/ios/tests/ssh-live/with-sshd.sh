#!/bin/sh
# Starts a throwaway, unprivileged sshd on 127.0.0.1 for the live SSH tests,
# runs one command against it, then removes everything it created.
#
#   tooling/ios/tests/ssh-live/with-sshd.sh -- \
#     flutter test test/remote/live_ssh_transport_test.dart
#
# Exports, for the command:
#   DSH_APP_LIVE_SSHD_PORT      loopback port the sshd listens on
#   DSH_APP_LIVE_SSHD_KEY       private key the test authenticates with
#   DSH_APP_LIVE_SSHD_PASS_KEY  passphrase-protected private key (authorized)
#   DSH_APP_LIVE_SSHD_PASSPHRASE its passphrase
#   DSH_APP_LIVE_SSHD_HOST_PUB  public host key (for the ssh-keygen comparison)
#   DSH_APP_LIVE_SSHD_USER      current account name
#   DSH_APP_LIVE_SSHD_WORK      fixture directory (read-only use by the test)
#
# Nothing under ~/.ssh is read or written: host key, client key and
# authorized_keys are generated inside one temp directory (mode 700), and only
# 127.0.0.1 is listened on. Password authentication is off; the password and
# keyboard-interactive paths are covered by the fake transport unit tests.
set -eu

[ "${1:-}" = "--" ] && shift
if [ "$#" -eq 0 ]; then
  echo "usage: $0 -- <command...>" >&2
  exit 2
fi

SSHD="$(command -v sshd 2>/dev/null || true)"
if [ -z "$SSHD" ] && [ -x /usr/sbin/sshd ]; then SSHD=/usr/sbin/sshd; fi
if [ -z "$SSHD" ] || [ ! -x "$SSHD" ]; then
  echo "with-sshd.sh: sshd is not installed" >&2
  exit 1
fi
command -v ssh-keygen >/dev/null 2>&1 || {
  echo "with-sshd.sh: ssh-keygen is not installed" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "with-sshd.sh: python3 is needed to pick a free port" >&2
  exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/dsh-live-sshd.XXXXXX")"
chmod 700 "$work"
pid=""

cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

ssh-keygen -q -t ed25519 -N '' -f "$work/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$work/client_key"
ssh-keygen -q -t ed25519 -N 'live-pass' -f "$work/client_pass_key"
cat "$work/client_key.pub" "$work/client_pass_key.pub" > "$work/authorized_keys"
chmod 600 "$work/host_key" "$work/client_key" "$work/client_pass_key" "$work/authorized_keys"

sftp_server="$(command -v sftp-server 2>/dev/null || true)"
if [ -z "$sftp_server" ] && [ -x /usr/lib/openssh/sftp-server ]; then sftp_server=/usr/lib/openssh/sftp-server; fi
if [ -z "$sftp_server" ] && [ -x /usr/libexec/sftp-server ]; then sftp_server=/usr/libexec/sftp-server; fi

port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

cat >"$work/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $work/host_key
PidFile $work/sshd.pid
AuthorizedKeysFile $work/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowTcpForwarding yes
AllowAgentForwarding no
X11Forwarding no
LogLevel ERROR
$( [ -n "$sftp_server" ] && printf 'Subsystem sftp %s\n' "$sftp_server" )
EOF

"$SSHD" -D -e -f "$work/sshd_config" >"$work/sshd.log" 2>&1 &
pid=$!

i=0
ready=""
while [ "$i" -lt 100 ]; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "with-sshd.sh: sshd exited while starting:" >&2
    cat "$work/sshd.log" >&2 || true
    exit 1
  fi
  if python3 - "$port" <<'PY'
import socket
import sys
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
  then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
if [ -z "$ready" ]; then
  echo "with-sshd.sh: sshd did not listen on 127.0.0.1:$port" >&2
  cat "$work/sshd.log" >&2 || true
  exit 1
fi

export DSH_APP_LIVE_SSHD_PORT="$port"
export DSH_APP_LIVE_SSHD_KEY="$work/client_key"
export DSH_APP_LIVE_SSHD_HOST_PUB="$work/host_key.pub"
export DSH_APP_LIVE_SSHD_PASS_KEY="$work/client_pass_key"
export DSH_APP_LIVE_SSHD_PASSPHRASE="live-pass"
export DSH_APP_LIVE_SSHD_USER="$(id -un)"
export DSH_APP_LIVE_SSHD_WORK="$work"

# A pty needs an allocatable /dev/pts. On hosts where devpts is mounted read-only
# the unprivileged sshd fails chown and closes the connection right after
# pty-req, so tests skip PTY instead of misreporting it as a client defect.
pty_ok=0
if command -v ssh >/dev/null 2>&1; then
  ssh -p "$port" -i "$work/client_key" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -tt "$DSH_APP_LIVE_SSHD_USER@127.0.0.1" true >/dev/null 2>&1 && pty_ok=1
fi
export DSH_APP_LIVE_SSHD_PTY="$pty_ok"

# CI sets this so a host that cannot allocate a pty fails here instead of
# letting the PTY tests skip and the run look green.
if [ "${DSH_APP_LIVE_SSHD_REQUIRE_PTY:-0}" = "1" ] && [ "$pty_ok" -ne 1 ]; then
  echo "with-sshd.sh: DSH_APP_LIVE_SSHD_REQUIRE_PTY=1 but this host cannot allocate a pty (devpts not writable by the unprivileged sshd?)" >&2
  cat "$work/sshd.log" >&2 2>/dev/null || true
  exit 1
fi

echo "with-sshd.sh: sshd on 127.0.0.1:$port (user $DSH_APP_LIVE_SSHD_USER, pty=$pty_ok)" >&2
"$@"
