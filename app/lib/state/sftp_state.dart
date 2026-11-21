// Server files over SFTP, independent of DSH: this works while the remote DSH
// is stopped, because it uses its own authenticated SSH connection
// ([SshSessionService]) instead of the DSH tunnel.
//
// Transfers are streamed in windows (256 KiB) so a large file never sits in
// memory. A write or a terminal command is never replayed automatically: a
// transfer that loses its connection ends as failed, with a partial file left
// on the server for the person to inspect, overwrite or delete.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SftpStatusError, SftpStatusCode, SSHStateError;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/ssh/ssh_session_capabilities.dart';
import '../remote/ssh/ssh_session_service.dart';
import 'hosts_state.dart';
import 'ssh_session_state.dart';

/// What went wrong, in terms the UI can turn into words. The state layer keeps
/// no localized text: the person's language is the widget's business.
enum SftpFailureKind {
  notConnected,
  notFound,
  permissionDenied,
  alreadyExists,
  notEmpty,
  isDirectory,
  unsupported,
  cancelled,
  connectionLost,
  tooLarge,
  other,
}

class SftpFailure implements Exception {
  const SftpFailure(this.kind, {this.detail});

  final SftpFailureKind kind;
  final String? detail;

  @override
  String toString() => detail == null ? 'SftpFailure($kind)' : 'SftpFailure($kind): $detail';
}

SftpFailure sftpFailureOf(Object error) {
  if (error is SftpFailure) return error;
  if (error is SftpStatusError) {
    final detail = error.message;
    return switch (error.code) {
      SftpStatusCode.noSuchFile => SftpFailure(SftpFailureKind.notFound, detail: detail),
      SftpStatusCode.permissionDenied => SftpFailure(SftpFailureKind.permissionDenied, detail: detail),
      SftpStatusCode.noConnection ||
      SftpStatusCode.connectionLost => SftpFailure(SftpFailureKind.connectionLost, detail: detail),
      SftpStatusCode.opUnsupported => SftpFailure(SftpFailureKind.unsupported, detail: detail),
      _ => SftpFailure(SftpFailureKind.other, detail: detail),
    };
  }
  if (error is HostLinkError) {
    return SftpFailure(
      error.retryable ? SftpFailureKind.connectionLost : SftpFailureKind.notConnected,
      detail: error.message,
    );
  }
  // The SFTP channel or the connection beneath it died mid-operation.
  if (error is SSHStateError) return SftpFailure(SftpFailureKind.connectionLost, detail: '$error');
  if (error is FormatException) return SftpFailure(SftpFailureKind.other, detail: error.message);
  return SftpFailure(SftpFailureKind.other, detail: '$error');
}

enum SftpPhase { idle, connecting, ready, failed }

enum SftpTransferStatus { running, done, failed, cancelled }

/// One file or folder of the current directory.
class SftpEntry {
  const SftpEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.isSymbolicLink,
    this.size,
    this.modified,
    this.mode,
  });

  final String name;

  /// Absolute server path.
  final String path;
  final bool isDirectory;
  final bool isSymbolicLink;
  final int? size;
  final DateTime? modified;
  final int? mode;

  /// `644` style permissions for the list.
  int? get permissionBits => mode == null ? null : mode! & 0x1FF;
}

/// One upload or download, shown by the transfer centre.
class SftpTransfer {
  const SftpTransfer({
    required this.id,
    required this.name,
    required this.remotePath,
    required this.localPath,
    required this.upload,
    required this.status,
    this.total,
    this.done = 0,
    this.error,
  });

  final String id;
  final String name;

  /// Absolute server path.
  final String remotePath;

  /// Absolute phone path (app container while the app owns it).
  final String localPath;
  final bool upload;
  final int? total;
  final int done;
  final SftpTransferStatus status;
  final SftpFailure? error;

  bool get running => status == SftpTransferStatus.running;

  double? get fraction => total == null || total == 0 ? null : (done / total!).clamp(0, 1);

  SftpTransfer copyWith({
    int? total,
    int? done,
    SftpTransferStatus? status,
    SftpFailure? error,
    bool clearError = false,
  }) => SftpTransfer(
    id: id,
    name: name,
    remotePath: remotePath,
    localPath: localPath,
    upload: upload,
    total: total ?? this.total,
    done: done ?? this.done,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
  );
}

class SftpState {
  const SftpState({
    this.phase = SftpPhase.idle,
    this.path = '/',
    this.entries = const [],
    this.failure,
    this.transfers = const [],
    this.busy = false,
    this.searchResults = const [],
    this.searching = false,
  });

  final SftpPhase phase;

  /// Absolute server directory shown.
  final String path;
  final List<SftpEntry> entries;
  final SftpFailure? failure;
  final List<SftpTransfer> transfers;

  /// A listing or file operation is in flight (not a transfer).
  final bool busy;

  /// Last search result set; empty while no search ran or after [clearSearch].
  final List<SftpEntry> searchResults;

  /// A [SftpController.search] walk is running.
  final bool searching;

  bool get ready => phase == SftpPhase.ready;
  bool get uploading => transfers.any((t) => t.upload && t.running);
  bool get downloading => transfers.any((t) => !t.upload && t.running);

  SftpState copyWith({
    SftpPhase? phase,
    String? path,
    List<SftpEntry>? entries,
    SftpFailure? failure,
    bool clearFailure = false,
    List<SftpTransfer>? transfers,
    bool? busy,
    List<SftpEntry>? searchResults,
    bool? searching,
  }) => SftpState(
    phase: phase ?? this.phase,
    path: path ?? this.path,
    entries: entries ?? this.entries,
    failure: clearFailure ? null : (failure ?? this.failure),
    transfers: transfers ?? this.transfers,
    busy: busy ?? this.busy,
    searchResults: searchResults ?? this.searchResults,
    searching: searching ?? this.searching,
  );
}

class SftpController extends Notifier<SftpState> {
  SftpController(this.host);

  final HostRef host;

  static const chunkSize = 256 * 1024;

  SshSessionService? _service;
  SshFileSession? _files;
  StreamSubscription<void>? _lost;
  final Set<String> _cancelled = {};
  var _transferSeq = 0;
  var _searchCancelled = false;
  var _disposed = false;

  @override
  SftpState build() {
    // Watched, so the page keeps the shared SSH session alive and it closes
    // when the last file/terminal page goes away.
    _service = ref.watch(sshSessionServiceProvider(host));
    ref.onDispose(() {
      _disposed = true;
      unawaited(_lost?.cancel());
      _lost = null;
      final files = _files;
      _files = null;
      if (files != null) unawaited(files.close().catchError((_) {}));
    });
    if (host.kind != HostKind.ssh) {
      return const SftpState(phase: SftpPhase.failed, failure: SftpFailure(SftpFailureKind.unsupported));
    }
    return const SftpState();
  }

  /// Opens the SSH connection (no DSH involved) and lists [path].
  Future<void> connect({String path = '/'}) async {
    if (state.phase == SftpPhase.connecting) return;
    state = state.copyWith(phase: SftpPhase.connecting, clearFailure: true, busy: true);
    try {
      final service = _service;
      if (service == null) throw const SftpFailure(SftpFailureKind.unsupported);
      _lost ??= service.lost.listen((_) => _onLost());
      final files = await service.openFiles();
      if (_disposed) {
        await files.close();
        return;
      }
      _files = files;
      await _list(path);
    } on SftpFailure catch (error) {
      _fail(error);
    } catch (error) {
      _fail(sftpFailureOf(error));
    }
  }

  /// Explicit retry after a failure; nothing is resumed or replayed.
  Future<void> retry() async {
    final files = _files;
    _files = null;
    if (files != null) await files.close().catchError((_) {});
    // Drops the dead connection and opens a new one. A terminal tab that shared
    // it already ended with the loss and is not replayed.
    await _service?.reconnect();
    await connect(path: state.path);
  }

  /// Lists an absolute server directory.
  Future<void> open(String path) async {
    if (!state.ready) return connect(path: path);
    state = state.copyWith(busy: true, clearFailure: true);
    try {
      await _list(path);
    } catch (error) {
      _fail(sftpFailureOf(error));
    }
  }

  Future<void> refresh() => open(state.path);

  /// One level up, never above `/`.
  Future<void> up() {
    final current = state.path;
    if (current == '/' || current.isEmpty) return Future.value();
    final cut = current.lastIndexOf('/');
    return open(cut <= 0 ? '/' : current.substring(0, cut));
  }

  Future<void> createDirectory(String name) async {
    final files = _requireFiles();
    final path = _child(state.path, name);
    await _run(() => files.makeDirectory(path));
    await refresh();
  }

  /// Renames inside the current directory; the person gives the new name.
  Future<void> rename(String path, String newName) async {
    final files = _requireFiles();
    final parent = path.substring(0, path.lastIndexOf('/'));
    await _run(() => files.rename(path, _child(parent.isEmpty ? '/' : parent, newName)));
    await refresh();
  }

  /// Deletes one entry. [directory] comes from the entry the UI confirmed.
  Future<void> remove(String path, {required bool directory}) async {
    final files = _requireFiles();
    await _run(() => files.remove(path, directory: directory));
    await refresh();
  }

  Future<void> chmod(String path, int mode) async {
    final files = _requireFiles();
    await _run(() => files.chmod(path, mode));
    await refresh();
  }

  /// Reads a text file for the editor; refuses files too large to edit.
  Future<String> readText(String path, {int maxBytes = 2 * 1024 * 1024}) async {
    final files = _requireFiles();
    try {
      final stat = await files.stat(path);
      if (!stat.isRegularFile) throw const SftpFailure(SftpFailureKind.isDirectory);
      final size = stat.size;
      if (size != null && size > maxBytes) throw const SftpFailure(SftpFailureKind.tooLarge);
      final bytes = await files.readRange(path, length: maxBytes);
      return utf8.decode(bytes, allowMalformed: true);
    } catch (error) {
      throw sftpFailureOf(error);
    }
  }

  /// Replaces a text file (the editor's save). One write, no retry: a failure
  /// may have written part of it, so the UI must ask before trying again.
  Future<void> writeText(String path, String text) async {
    final files = _requireFiles();
    await _run(() => files.writeRange(path, Uint8List.fromList(utf8.encode(text)), truncate: true));
    await refresh();
  }

  /// Streams [remotePath] into the phone file [localPath]. A cancelled or
  /// failed transfer leaves the partial local file for the person to delete.
  Future<void> download({required String remotePath, required String localPath}) async {
    final id = _nextTransferId();
    _addTransfer(
      SftpTransfer(
        id: id,
        name: remotePath.split('/').last,
        remotePath: remotePath,
        localPath: localPath,
        upload: false,
        status: SftpTransferStatus.running,
      ),
    );
    await _downloadInto(id, remotePath, localPath);
  }

  Future<void> _downloadInto(String id, String remotePath, String localPath) async {
    final files = _requireFiles();
    RandomAccessFile? target;
    try {
      final stat = await files.stat(remotePath);
      if (!stat.isRegularFile) throw const SftpFailure(SftpFailureKind.isDirectory);
      _updateTransfer(id, (t) => t.copyWith(total: stat.size));
      target = await File(localPath).open(mode: FileMode.write);
      var offset = 0;
      while (true) {
        if (_cancelled.contains(id)) {
          _finishTransfer(id, SftpTransferStatus.cancelled);
          return;
        }
        final chunk = await files.readRange(remotePath, offset: offset, length: chunkSize);
        if (chunk.isEmpty) break;
        await target.writeFrom(chunk);
        offset += chunk.length;
        _updateTransfer(id, (t) => t.copyWith(done: offset));
      }
      // A cancel that arrived while the last chunk was in flight wins: the
      // file is complete, but the person asked to stop, so say cancelled.
      _finishTransfer(
        id,
        _cancelled.contains(id) ? SftpTransferStatus.cancelled : SftpTransferStatus.done,
        done: offset,
      );
    } on SftpFailure catch (error) {
      _finishTransfer(id, SftpTransferStatus.failed, error: error);
    } catch (error) {
      _finishTransfer(id, SftpTransferStatus.failed, error: sftpFailureOf(error));
    } finally {
      await target?.close().catchError((_) {});
      _cancelled.remove(id);
    }
  }

  /// Streams the phone file [localPath] to [remoteDir]. A failure leaves the
  /// bytes already written on the server; nothing resumes automatically.
  Future<void> upload({required String localPath, required String remoteDir}) async {
    final name = localPath.split('/').last;
    final id = _nextTransferId();
    int? total;
    try {
      total = await File(localPath).length();
    } catch (_) {
      total = null;
    }
    _addTransfer(
      SftpTransfer(
        id: id,
        name: name,
        remotePath: _child(remoteDir, name),
        localPath: localPath,
        upload: true,
        total: total,
        status: SftpTransferStatus.running,
      ),
    );
    await _uploadInto(id, localPath, remoteDir);
  }

  Future<void> _uploadInto(String id, String localPath, String remoteDir) async {
    final files = _requireFiles();
    final source = File(localPath);
    final remotePath = _child(remoteDir, localPath.split('/').last);
    var written = 0;
    var first = true;
    try {
      await for (final chunk in source.openRead()) {
        if (_cancelled.contains(id)) {
          _finishTransfer(id, SftpTransferStatus.cancelled, done: written);
          return;
        }
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        await files.writeRange(remotePath, bytes, offset: written, create: first, truncate: first);
        first = false;
        written += bytes.length;
        _updateTransfer(id, (t) => t.copyWith(done: written));
      }
      // A zero-byte source never enters the loop, so an empty upload still has
      // to create (or truncate over) the remote file — otherwise "uploading an
      // empty file" would report success and change nothing on the server.
      if (first) {
        await files.writeRange(remotePath, Uint8List(0), create: true, truncate: true);
      }
      // A cancel that landed while the last chunk was in flight wins.
      final cancelled = _cancelled.contains(id);
      _finishTransfer(
        id,
        cancelled ? SftpTransferStatus.cancelled : SftpTransferStatus.done,
        done: written,
      );
      if (!cancelled) await refresh();
    } on SftpFailure catch (error) {
      _finishTransfer(id, SftpTransferStatus.failed, done: written, error: error);
    } catch (error) {
      _finishTransfer(id, SftpTransferStatus.failed, done: written, error: sftpFailureOf(error));
    } finally {
      _cancelled.remove(id);
    }
  }

  /// Copies one file to exactly [to] over the same session, in windows, so a
  /// large file never sits in memory. Batches are the caller's loop: this does
  /// one entry, never a directory tree, and never follows a symlinked
  /// directory. A directory source is refused as [SftpFailureKind.unsupported].
  Future<void> copy({required String from, required String to}) async {
    final files = _requireFiles();
    if (from == to) return;
    await _run(() async {
      final stat = await files.stat(from);
      if (stat.isDirectory) {
        throw const SftpFailure(SftpFailureKind.unsupported, detail: 'directory copy');
      }
      var offset = 0;
      var first = true;
      while (true) {
        final chunk = await files.readRange(from, offset: offset, length: chunkSize);
        if (chunk.isEmpty) break;
        await files.writeRange(to, chunk, offset: offset, create: first, truncate: first);
        first = false;
        offset += chunk.length;
      }
      if (first) {
        await files.writeRange(to, Uint8List(0), create: true, truncate: true);
      }
    });
    await refresh();
  }

  /// Moves one entry to exactly [to] with a server-side rename. A symlink moves
  /// as itself; nothing is followed or recursively rewritten.
  Future<void> move({required String from, required String to}) async {
    final files = _requireFiles();
    if (from == to) return;
    await _run(() => files.rename(from, to));
    await refresh();
  }

  /// Whole-file bytes for an image/PDF preview. Bounded: over [maxBytes] it
  /// throws [SftpFailureKind.tooLarge] instead of reading an unbounded file.
  Future<Uint8List> readBytes(String path, {int maxBytes = 8 * 1024 * 1024}) async {
    final files = _requireFiles();
    try {
      final stat = await files.stat(path);
      if (!stat.isRegularFile) throw const SftpFailure(SftpFailureKind.isDirectory);
      final size = stat.size;
      if (size != null && size > maxBytes) throw const SftpFailure(SftpFailureKind.tooLarge);
      final out = BytesBuilder(copy: false);
      var offset = 0;
      while (offset < maxBytes) {
        final want = maxBytes - offset;
        final chunk = await files.readRange(path, offset: offset, length: want);
        if (chunk.isEmpty) break;
        out.add(chunk);
        offset += chunk.length;
      }
      if (offset >= maxBytes) throw const SftpFailure(SftpFailureKind.tooLarge);
      return out.takeBytes();
    } catch (error) {
      throw sftpFailureOf(error);
    }
  }

  /// Lists any absolute directory without changing the one on screen. The
  /// caller uses this to walk the tree (search); [open] is the only method that
  /// moves the browser.
  Future<List<SftpEntry>> listDir(String path) async {
    final files = _requireFiles();
    final names = await _runRead(() => files.list(path));
    return _entriesFor(path, names);
  }

  /// Recursively looks for [query] in file names under [root] (defaults to the
  /// current directory). Symlinked directories are never entered, unreadable
  /// directories are skipped rather than failing the whole search, and the
  /// walk stops at [maxResults] matches or [maxDirectories] visited folders.
  Future<List<SftpEntry>> search(
    String query, {
    String? root,
    bool includeHidden = false,
    int maxResults = 200,
    int maxDirectories = 500,
  }) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      state = state.copyWith(searchResults: const [], searching: false);
      return const [];
    }
    final files = _requireFiles();
    _searchCancelled = false;
    state = state.copyWith(searching: true, searchResults: const []);
    final found = <SftpEntry>[];
    final pending = <String>[root ?? state.path];
    var visited = 0;
    try {
      while (pending.isNotEmpty && found.length < maxResults && !_searchCancelled) {
        final directory = pending.removeAt(0);
        if (visited++ >= maxDirectories) break;
        final List<SshFileEntry> names;
        try {
          names = await files.list(directory);
        } catch (_) {
          // One unreadable folder (permissions, a race with a delete) is not a
          // reason to lose the matches already found.
          continue;
        }
        for (final name in names) {
          if (!includeHidden && name.name.startsWith('.')) continue;
          final path = _child(directory, name.name);
          if (name.name.toLowerCase().contains(needle)) {
            found.add(
              SftpEntry(
                name: name.name,
                path: path,
                isDirectory: name.isDirectory,
                isSymbolicLink: name.isSymbolicLink,
                size: name.size,
                modified: name.modified,
                mode: name.mode,
              ),
            );
            if (found.length >= maxResults) break;
          }
          // Never walk through a symlinked directory: the server could point it
          // anywhere, including back into the tree being searched.
          if (name.isDirectory && !name.isSymbolicLink) pending.add(path);
        }
      }
    } finally {
      if (!_disposed) state = state.copyWith(searchResults: found, searching: false);
      _searchCancelled = false;
    }
    return found;
  }

  /// Stops the walk after the directory in flight; partial matches stay shown.
  void cancelSearch() => _searchCancelled = true;

  void clearSearch() {
    state = state.copyWith(searchResults: const [], searching: false);
  }

  /// Explicit retry of a settled transfer. Nothing retries on its own: a
  /// failed or cancelled transfer waits for this call. The row keeps its id so
  /// the page can keep watching the same progress entry.
  Future<void> retryTransfer(String id) async {
    SftpTransfer? transfer;
    for (final candidate in state.transfers) {
      if (candidate.id == id) transfer = candidate;
    }
    if (transfer == null || transfer.running) return;
    _updateTransfer(
      id,
      (t) => t.copyWith(status: SftpTransferStatus.running, done: 0, clearError: true),
    );
    final cut = transfer.remotePath.lastIndexOf('/');
    final remoteDir = cut <= 0 ? '/' : transfer.remotePath.substring(0, cut);
    if (transfer.upload) {
      await _uploadInto(id, transfer.localPath, remoteDir);
    } else {
      await _downloadInto(id, transfer.remotePath, transfer.localPath);
    }
  }

  String _nextTransferId() => 'xfer-${_transferSeq++}';

  /// Stops after the chunk in flight; the partial file stays where it is.
  /// A transfer that already settled is left alone: cancelling it would rewrite
  /// a real success (or failure) as "cancelled".
  void cancel(String id) {
    SftpTransfer? transfer;
    for (final candidate in state.transfers) {
      if (candidate.id == id) transfer = candidate;
    }
    if (transfer == null || !transfer.running) return;
    _cancelled.add(id);
    _updateTransfer(id, (t) => t.copyWith(status: SftpTransferStatus.cancelled));
  }

  void clearFinished() {
    state = state.copyWith(
      transfers: [
        for (final transfer in state.transfers)
          if (transfer.running) transfer,
      ],
    );
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  SshFileSession _requireFiles() {
    final files = _files;
    if (files == null || !state.ready) throw const SftpFailure(SftpFailureKind.notConnected);
    return files;
  }

  Future<void> _list(String path) async {
    // Connecting is not ready yet: the internal path must not require it.
    final files = _files;
    if (files == null) throw const SftpFailure(SftpFailureKind.notConnected);
    final names = await _runRead(() => files.list(path));
    final entries = _entriesFor(path, names);
    if (_disposed) return;
    state = state.copyWith(
      phase: SftpPhase.ready,
      path: path,
      entries: entries,
      clearFailure: true,
      busy: false,
    );
  }

  Future<void> _run(Future<void> Function() body) async {
    try {
      await body();
    } catch (error) {
      throw sftpFailureOf(error);
    }
  }

  Future<T> _runRead<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (error) {
      throw sftpFailureOf(error);
    }
  }

  void _fail(SftpFailure failure) {
    if (_disposed) return;
    state = state.copyWith(phase: SftpPhase.failed, failure: failure, busy: false);
  }

  void _onLost() {
    final files = _files;
    _files = null;
    if (files != null) unawaited(files.close().catchError((_) {}));
    _fail(const SftpFailure(SftpFailureKind.connectionLost));
  }

  void _addTransfer(SftpTransfer transfer) {
    if (_disposed) return;
    state = state.copyWith(transfers: [transfer, ...state.transfers]);
  }

  void _updateTransfer(String id, SftpTransfer Function(SftpTransfer) update) {
    if (_disposed) return;
    state = state.copyWith(
      transfers: [
        for (final transfer in state.transfers)
          if (transfer.id == id) update(transfer) else transfer,
      ],
    );
  }

  void _finishTransfer(
    String id,
    SftpTransferStatus status, {
    int? done,
    SftpFailure? error,
  }) {
    _updateTransfer(id, (t) => t.copyWith(status: status, done: done, error: error));
  }

  static List<SftpEntry> _entriesFor(String directory, List<SshFileEntry> names) {
    final entries = [
      for (final entry in names)
        SftpEntry(
          name: entry.name,
          path: _child(directory, entry.name),
          isDirectory: entry.isDirectory,
          isSymbolicLink: entry.isSymbolicLink,
          size: entry.size,
          modified: entry.modified,
          mode: entry.mode,
        ),
    ]..sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  static String _child(String directory, String name) {
    if (name.startsWith('/')) return name;
    if (directory == '/' || directory.isEmpty) return '/$name';
    return '$directory/$name';
  }
}

/// Server files of the active SSH host; the family is the host, so two hosts
/// never share a session, a directory or a transfer list.
final sftpProvider = NotifierProvider.autoDispose.family<SftpController, SftpState, HostRef>(SftpController.new);

/// Convenience for pages: the entry list of the host's last directory, empty
/// until [SftpController.connect] ran.
String? sftpParentOf(String path) {
  if (path == '/' || path.isEmpty) return null;
  final cut = path.lastIndexOf('/');
  return cut <= 0 ? '/' : path.substring(0, cut);
}
