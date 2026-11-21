// Finds a DSH instance that is already running on the SSH server.
//
// Explicit user action only. The scan is one read-only shell script: it reads
// command lines, start times and socket inodes of the SSH account's own
// processes and never opens another process's environment, files or memory.
//
// The script only reports facts (pid, start time, ports, command, and - for the
// pid named in this app's own `web.pid` - the token from this app's own log).
// Whether an instance counts as managed is decided here: the pid must still be
// the recorded one AND its start time must equal the recorded `web.st`. Without
// that proof an instance is unknown, is not labelled managed and keeps no
// token. Nothing here stops, starts or restarts anything.

import 'dart:async';

import 'remote_shell.dart';

/// One `dsh web` running on the server.
class RemoteDshInstance {
  const RemoteDshInstance({
    required this.pid,
    required this.command,
    this.ports = const [],
    this.managed = false,
    this.token,
  });

  final int pid;

  /// The process command line, shortened and stripped of launch tokens.
  final String command;

  /// Listening ports that belong to this process (TCP, including IPv6).
  final List<int> ports;

  /// This app started it: its pid is in `~/.dsh-app-remote/web.pid` **and**
  /// its start time still matches the recorded one. A bare pid match is not
  /// enough (pids are recycled), so it stays false.
  final bool managed;

  /// Launch token from this app's own managed log; null whenever ownership is
  /// not proven, and for instances the person started by hand.
  final String? token;

  /// A tunnel needs a port; without one the person has to look it up.
  bool get attachable => ports.isNotEmpty;
}

/// Scans the server for running DSH instances. See the file comment for what
/// the script may and may not read.
Future<List<RemoteDshInstance>> discoverDshInstances(
  RemoteShell shell, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final result = await shell.run(discoveryScript(), timeout: timeout);
  return parseDshInstances(result.stdout);
}

/// The scan script: POSIX sh, no writes outside a private temp directory.
///
/// Lines: `DSHAPP state <recorded pid|-> <recorded start|->`,
/// `DSHAPP inst <pid> <start|-> <ports|-> <command>`,
/// `DSHAPP token <pid> <token>` (only for the pid this app recorded).
String discoveryScript() {
  return r'''
T=$(mktemp -d "${TMPDIR:-/tmp}/dsh-instances.XXXXXX") || exit 70
trap 'rm -rf "$T"' 0
D="$HOME/.dsh-app-remote"
_st() {
  if [ -r "/proc/$1/stat" ]; then
    S=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    S=${S##*) }
    set -- $S
    [ "$#" -ge 20 ] || return 1
    shift 19
    printf '%s\n' "$1"
  else
    ps -p "$1" -o lstart= 2>/dev/null
  fi
}
printf 'DSHAPP home %s\n' "$HOME"
RP=$(cat "$D/web.pid" 2>/dev/null) || RP=-
RS=$(cat "$D/web.st" 2>/dev/null) || RS=-
[ -n "$RP" ] || RP=-
[ -n "$RS" ] || RS=-
printf 'DSHAPP state %s %s\n' "$RP" "$RS"
for d in /proc/[0-9]*; do
  P=${d#/proc/}
  [ -r "$d/cmdline" ] || continue
  C=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
  [ -n "$C" ] || continue
  A0=${C%% *}
  case "${A0##*/}" in
    dsh|node|npx|bun|deno) ;;
    *) continue ;;
  esac
  case "$C" in
    *web*) ;;
    *) continue ;;
  esac
  printf '%s\n' "$C" > "$T/cmd.$P"
  : > "$T/port.$P"
  for f in "$d"/fd/*; do
    L=$(readlink "$f" 2>/dev/null) || continue
    case "$L" in
      'socket:['*']')
        I=${L#socket:[}
        I=${I%]}
        printf '%s %s\n' "$I" "$P" >> "$T/inodes"
        ;;
    esac
  done
done
if [ -s "$T/inodes" ]; then
  for nf in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$nf" ] || continue
    while read -r sl laddr raddr st tq tm rt uid timeout inode rest; do
      [ "$st" = 0A ] || continue
      case "$laddr" in
        *:*) ;;
        *) continue ;;
      esac
      O=$(awk -v i="$inode" '$1 == i { print $2; exit }' "$T/inodes")
      [ -n "$O" ] || continue
      H=${laddr##*:}
      printf '%s\n' "$((0x$H))" >> "$T/port.$O"
    done < "$nf"
  done
fi
for c in "$T"/cmd.*; do
  [ -f "$c" ] || continue
  P=${c##*/cmd.}
  CMD=$(cut -c1-200 "$c")
  ST=$(_st "$P") || ST=-
  [ -n "$ST" ] || ST=-
  PORTS=""
  if [ -f "$T/port.$P" ]; then
    for x in $(sort -un "$T/port.$P"); do PORTS="${PORTS}${PORTS:+,}$x"; done
  fi
  [ -n "$PORTS" ] || PORTS=-
  printf 'DSHAPP inst %s %s %s %s\n' "$P" "$ST" "$PORTS" "$CMD"
  if [ -f "$D/web.pid" ] && [ "$(cat "$D/web.pid" 2>/dev/null)" = "$P" ] && [ -f "$D/web.log" ]; then
    L=$(grep -E 'https?://[^ ]*[?&]token=' "$D/web.log" 2>/dev/null | tail -n 1)
    case "$L" in
      *token=*)
        TK=${L##*token=}
        TK=${TK%%&*}
        TK=${TK%% *}
        [ -n "$TK" ] && printf 'DSHAPP token %s %s\n' "$P" "$TK"
        ;;
    esac
  fi
done
true
''';
}

/// Parses [discoveryScript] output; unknown and half-written lines are
/// ignored so a login banner or a killed scan cannot invent an instance.
List<RemoteDshInstance> parseDshInstances(String stdout) {
  String? recordedPid;
  String? recordedStart;
  final tokens = <int, String>{};
  final found = <int, ({String start, String command, List<int> ports})>{};
  for (final raw in stdout.split('\n')) {
    final line = raw.trimRight();
    if (!line.startsWith('DSHAPP ')) continue;
    final rest = line.substring('DSHAPP '.length);
    final space = rest.indexOf(' ');
    if (space < 0) continue;
    final key = rest.substring(0, space);
    final value = rest.substring(space + 1);
    switch (key) {
      case 'state':
        final parts = value.split(' ');
        if (parts.length < 2) continue;
        recordedPid = _value(parts[0]);
        recordedStart = _value(parts[1]);
      case 'inst':
        final first = value.indexOf(' ');
        final second = first < 0 ? -1 : value.indexOf(' ', first + 1);
        final third = second < 0 ? -1 : value.indexOf(' ', second + 1);
        if (third < 0) continue;
        final pid = int.tryParse(value.substring(0, first));
        if (pid == null || pid <= 0) continue;
        found[pid] = (
          start: _value(value.substring(first + 1, second)) ?? '',
          ports: _ports(value.substring(second + 1, third)),
          command: redactRemoteTokens(value.substring(third + 1).trim()),
        );
      case 'token':
        final space2 = value.indexOf(' ');
        if (space2 < 0) continue;
        final pid = int.tryParse(value.substring(0, space2));
        final token = value.substring(space2 + 1).trim();
        if (pid != null && token.isNotEmpty) tokens[pid] = token;
    }
  }
  final instances = [
    for (final entry in found.entries)
      if (_managed(entry.key, entry.value.start, recordedPid, recordedStart))
        RemoteDshInstance(
          pid: entry.key,
          command: entry.value.command,
          ports: entry.value.ports,
          managed: true,
          token: tokens[entry.key],
        )
      else
        RemoteDshInstance(
          pid: entry.key,
          command: entry.value.command,
          ports: entry.value.ports,
        ),
  ]..sort((a, b) {
    if (a.managed != b.managed) return a.managed ? -1 : 1;
    return a.pid.compareTo(b.pid);
  });
  return instances;
}

/// Ownership needs both halves: the same pid the app recorded, and the same
/// process start time it recorded. One without the other is not proof.
bool _managed(int pid, String start, String? recordedPid, String? recordedStart) {
  if (start.isEmpty) return false;
  if (recordedPid == null || recordedStart == null) return false;
  if (recordedPid != '$pid') return false;
  return start == recordedStart;
}

/// A `-` field means "the server did not report it".
String? _value(String field) {
  final value = field.trim();
  return value.isEmpty || value == '-' ? null : value;
}

List<int> _ports(String value) {
  if (value == '-' || value.isEmpty) return const [];
  final ports = <int>[];
  for (final part in value.split(',')) {
    final port = int.tryParse(part);
    if (port != null && port > 0 && port <= 65535) ports.add(port);
  }
  return ports;
}
