// What a live SSH connection can open besides tunnels: files (SFTP) and
// interactive shells (PTY).
//
// These are deliberately separate from [SshTransport]: the remote workbench
// only offers 服务器文件 / SSH 终端 on a transport that also implements
// [SshSessionHost], so relay links and test transports keep compiling and a
// page can say "服务端不支持" instead of pretending.

import 'dart:async';
import 'dart:typed_data';

/// A transport that can serve SFTP and PTY on the same SSH connection.
abstract interface class SshSessionHost {
  bool get supportsSftp;
  bool get supportsPty;

  /// One SFTP session over this connection. Close it when the page goes away;
  /// the SSH connection itself stays open.
  Future<SshFileSession> openSftp();

  /// One interactive shell with a pty. [options] size the initial window.
  Future<SshPtySession> openPty([SshPtyOptions options = const SshPtyOptions()]);
}

/// The terminal a shell session announces and its initial window.
class SshPtyOptions {
  const SshPtyOptions({this.term = 'xterm-256color', this.columns = 80, this.rows = 24})
    : assert(columns > 0),
      assert(rows > 0);

  final String term;
  final int columns;
  final int rows;
}

/// One interactive remote shell. Output is bytes: the caller owns terminal
/// emulation and key mapping.
abstract interface class SshPtySession {
  /// Everything the shell writes, including its stderr (a pty merges them).
  Stream<Uint8List> get output;

  void write(List<int> data);

  /// Tells the remote side the window changed; no-op before the first output.
  void resize({required int columns, required int rows});

  /// Resolves with the shell's exit status, null when the server reported none.
  Future<int?> get exitCode;

  /// Completes when the channel is gone, for any reason.
  Future<void> get done;

  void close();
}

/// One entry of a server directory, as SFTP reports it.
class SshFileEntry {
  const SshFileEntry({
    required this.name,
    required this.isDirectory,
    required this.isSymbolicLink,
    this.size,
    this.modified,
    this.mode,
  });

  final String name;
  final bool isDirectory;
  final bool isSymbolicLink;
  final int? size;
  final DateTime? modified;

  /// Permission bits as SFTP reports them (0o755 etc.), without the type bits.
  final int? mode;
}

/// What SFTP says about one path.
class SshFileStat {
  const SshFileStat({
    required this.isDirectory,
    required this.isSymbolicLink,
    required this.isRegularFile,
    this.size,
    this.modified,
    this.mode,
  });

  final bool isDirectory;
  final bool isSymbolicLink;
  final bool isRegularFile;
  final int? size;
  final DateTime? modified;
  final int? mode;
}

/// The file operations the server browser needs. Every path is absolute on
/// the server; callers turn `~` into a path themselves (SFTP does not expand
/// it unless the server does).
abstract interface class SshFileSession {
  Future<List<SshFileEntry>> list(String path);

  Future<SshFileStat> stat(String path, {bool followLinks = true});

  /// Reads at most [length] bytes from [offset]; null [length] reads to the
  /// end. Large files are read in windows by the caller.
  Future<Uint8List> readRange(String path, {int offset = 0, int? length});

  /// Writes [bytes] at [offset]. With [truncate] the file is replaced;
  /// otherwise the write lands in place. [append] ignores [offset].
  Future<void> writeRange(
    String path,
    Uint8List bytes, {
    int offset = 0,
    bool create = true,
    bool truncate = false,
    bool append = false,
  });

  Future<void> makeDirectory(String path);

  Future<void> remove(String path, {bool directory = false});

  Future<void> rename(String from, String to);

  /// Sets the permission bits ([mode] is 0o644 style, no type bits).
  Future<void> chmod(String path, int mode);

  /// [path] as an absolute server path (SFTP `realpath`; resolves `.` and `..`).
  Future<String> absolute(String path);

  /// Ends the SFTP session. The SSH connection stays open.
  Future<void> close();
}
