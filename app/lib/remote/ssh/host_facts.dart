// Facts a host reports about itself for 主机信息. One read-only script, one
// parse: no state is changed, nothing is written, and every field is optional
// because busybox, macOS and Linux answer differently.

import 'remote_shell.dart';

/// Read-only; prints `key=value` lines. Each probe falls back to empty when the
/// command is missing, so an unusual server still shows the rest.
const hostFactsScript = r'''
p() { printf '%s=%s\n' "$1" "$2"; }
p os "$(uname -s 2>/dev/null)"
p kernel "$(uname -r 2>/dev/null)"
p arch "$(uname -m 2>/dev/null)"
p host "$(hostname 2>/dev/null)"
p cpus "$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
p mem_kb "$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)"
p mem_bytes "$(sysctl -n hw.memsize 2>/dev/null)"
p load "$(cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null)"
p uptime "$(cut -d' ' -f1 /proc/uptime 2>/dev/null || sysctl -n kern.boottime 2>/dev/null)"
p disk "$(df -k / 2>/dev/null | tail -n 1)"
''';

/// What [hostFactsScript] answered, in the units the page shows.
class HostFacts {
  const HostFacts({
    this.os,
    this.kernel,
    this.arch,
    this.hostname,
    this.cpus,
    this.memoryBytes,
    this.load,
    this.uptime,
    this.diskTotalBytes,
    this.diskFreeBytes,
  });

  final String? os;
  final String? kernel;
  final String? arch;
  final String? hostname;
  final int? cpus;
  final int? memoryBytes;

  /// Load averages as the server reported them (1/5/15 on Linux, `{ a b c }` on
  /// macOS); kept as text because their formats differ.
  final String? load;
  final Duration? uptime;
  final int? diskTotalBytes;
  final int? diskFreeBytes;

  /// True when at least the kernel fields came through; a page with nothing to
  /// show should offer a retry instead of an empty card.
  bool get any => os != null || kernel != null || arch != null || hostname != null;

  /// Parses the script's output. Unknown keys and empty values are ignored; a
  /// server that answers nothing yields an empty [HostFacts].
  static HostFacts parse(String stdout) {
    final values = <String, String>{};
    for (final line in stdout.split('\n')) {
      final cut = line.indexOf('=');
      if (cut <= 0) continue;
      final key = line.substring(0, cut).trim();
      final value = line.substring(cut + 1).trim();
      if (key.isEmpty || value.isEmpty) continue;
      values[key] = value;
    }
    final disk = _parseDf(values['disk']);
    return HostFacts(
      os: values['os'],
      kernel: values['kernel'],
      arch: values['arch'],
      hostname: values['host'],
      cpus: int.tryParse(values['cpus'] ?? ''),
      memoryBytes: _parseMemory(values),
      load: _parseLoad(values['load']),
      uptime: _parseUptime(values['uptime']),
      diskTotalBytes: disk?.$1,
      diskFreeBytes: disk?.$2,
    );
  }

  /// Bytes. The script reports the unit per key: MemTotal is kB, hw.memsize is
  /// already bytes, so a big machine cannot be misread as the smaller unit.
  static int? _parseMemory(Map<String, String> values) {
    final bytes = int.tryParse(values['mem_bytes'] ?? '');
    if (bytes != null && bytes > 0) return bytes;
    final kb = int.tryParse(values['mem_kb'] ?? '');
    if (kb == null || kb <= 0) return null;
    return kb * 1024;
  }

  /// `0.00 0.01 0.05 1/234 5678` on Linux, `{ 1.2 1.3 1.4 }` on macOS.
  static String? _parseLoad(String? raw) {
    if (raw == null) return null;
    final numbers = RegExp(r'[0-9]+\.[0-9]+').allMatches(raw).take(3).map((m) => m.group(0)!);
    if (numbers.isEmpty) return null;
    return numbers.join(' · ');
  }

  /// Seconds since boot on Linux; macOS `kern.boottime` is a timestamp, which is
  /// not a duration, so it is left out rather than shown wrong.
  static Duration? _parseUptime(String? raw) {
    final seconds = double.tryParse(raw ?? '');
    if (seconds == null || seconds <= 0) return null;
    return Duration(seconds: seconds.round());
  }

  /// `Filesystem 1024-blocks Used Available Capacity Mounted` → total, free.
  static (int, int)? _parseDf(String? raw) {
    if (raw == null) return null;
    // The mounted path can contain spaces; the last field is the mount point,
    // the fields before it are numbers in a fixed order.
    final first = raw.indexOf(' ');
    if (first < 0) return null;
    final rest = raw.substring(first).trim();
    final fields = rest.split(RegExp(r'\s+')).where((f) => f.isNotEmpty).toList();
    final numbers = [
      for (final field in fields.take(3)) ?int.tryParse(field),
    ];
    if (numbers.length < 3) return null;
    return (numbers[0] * 1024, numbers[2] * 1024);
  }
}

/// Runs [hostFactsScript] on [transport] and parses it. Read-only, so a failure
/// is reported to the caller instead of being retried.
Future<HostFacts> readHostFacts(RemoteShell shell) async {
  final result = await shell.run(hostFactsScript, timeout: const Duration(seconds: 12));
  return HostFacts.parse(result.stdout);
}
