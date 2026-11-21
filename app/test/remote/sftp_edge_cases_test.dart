// SFTP state edge cases found in review: an empty upload must still create or
// truncate the remote file, cancelling during the final chunk must never report
// "done", permission failures keep their specific kind, and two hosts never
// share a session or a failure.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/remote/ssh/remote_shell.dart';
import 'package:dsh_app/remote/ssh/ssh_session_capabilities.dart';
import 'package:dsh_app/remote/ssh/ssh_session_service.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sftp_state.dart';
import 'package:dsh_app/state/ssh_session_state.dart';
import 'package:dsh_app/ui/remote/sftp_temp_dir.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_path_provider.dart';
import 'support/fake_ssh.dart';

const _lab = HostRef.ssh('lab');
const _pc = HostRef.ssh('pc');

class _Files implements SshFileSession {
  _Files({this.gateWriteAt});

  /// Holds the write at this 0-based index (the last chunk of a two-chunk file).
  final int? gateWriteAt;
  Completer<void>? writeGate;

  /// Holds the read at exactly this offset (the last chunk of a download).
  int? gateReadOffset;
  Completer<void>? readGate;

  final List<(String, int, int, bool)> writes = [];
  final List<(String, int)> chmods = [];
  final List<String> removes = [];
  final Map<String, Uint8List> bytes = {};
  final Set<String> symlinks = {};
  final Map<String, String> symlinkTarget = {};
  final Set<String> dirs = {};
  Object? chmodError;
  Object? writeError;

  @override
  Future<List<SshFileEntry>> list(String path) async => [
    for (final name in bytes.keys.where((p) => p.startsWith('$path/') && !p.substring(path.length + 1).contains('/')))
      SshFileEntry(
        name: name.substring(path.length + 1),
        isDirectory: false,
        isSymbolicLink: false,
        size: bytes[name]!.length,
        mode: 0x1A4,
      ),
  ];

  @override
  Future<SshFileStat> stat(String path, {bool followLinks = true}) async {
    if (symlinks.contains(path)) {
      if (!followLinks) {
        return const SshFileStat(isDirectory: false, isSymbolicLink: true, isRegularFile: false, mode: 0x1FF);
      }
      path = symlinkTarget[path] ?? path;
    }
    final data = bytes[path];
    return SshFileStat(
      isDirectory: dirs.contains(path),
      isSymbolicLink: false,
      isRegularFile: data != null,
      size: data?.length ?? 0,
      mode: 0x1A4,
    );
  }

  @override
  Future<Uint8List> readRange(String path, {int offset = 0, int? length}) async {
    if (gateReadOffset != null && offset == gateReadOffset) {
      readGate = Completer<void>();
      await readGate!.future;
    }
    final data = bytes[path] ?? Uint8List(0);
    if (offset >= data.length) return Uint8List(0);
    final end = length == null ? data.length : (offset + length).clamp(0, data.length);
    return Uint8List.sublistView(data, offset, end);
  }

  @override
  Future<void> writeRange(
    String path,
    Uint8List data, {
    int offset = 0,
    bool create = true,
    bool truncate = false,
    bool append = false,
  }) async {
    if (gateWriteAt != null && writes.length == gateWriteAt) {
      writeGate = Completer<void>();
      await writeGate!.future;
    }
    if (writeError != null) throw writeError!;
    writes.add((path, offset, data.length, truncate));
    if (truncate) {
      bytes[path] = Uint8List.fromList(data);
    } else {
      final old = bytes[path] ?? Uint8List(0);
      final end = offset + data.length;
      final out = Uint8List(old.length > end ? old.length : end)..setAll(0, old);
      out.setRange(offset, end, data);
      bytes[path] = out;
    }
  }

  @override
  Future<void> makeDirectory(String path) async {}
  @override
  Future<void> remove(String path, {bool directory = false}) async => removes.add(path);
  final List<(String, String)> renames = [];
  @override
  Future<void> rename(String from, String to) async => renames.add((from, to));
  @override
  Future<void> chmod(String path, int mode) async {
    if (chmodError != null) throw chmodError!;
    chmods.add((path, mode));
  }

  @override
  Future<String> absolute(String path) async => path;
  @override
  Future<void> close() async {}
}

class _Transport implements SshTransport, SshSessionHost {
  _Transport(this.files);

  final _Files files;
  final _done = Completer<void>();
  var closed = false;

  @override
  bool get supportsSftp => !closed;
  @override
  bool get supportsPty => false;
  @override
  Future<SshFileSession> openSftp() async => files;
  @override
  Future<SshPtySession> openPty([SshPtyOptions options = const SshPtyOptions()]) => throw UnimplementedError();
  @override
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)}) async =>
      const RemoteExecResult(0, '', '');
  @override
  Future<TunnelChannel> openTunnel(String host, int port) => throw UnimplementedError();
  @override
  Future<void> ping({Duration timeout = const Duration(seconds: 10)}) async {}
  @override
  Future<void> get done => _done.future;
  @override
  bool get isClosed => closed;
  @override
  void close() {
    if (closed) return;
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }
}

SshSessionService _service(SshTransport transport) => SshSessionService(
  config: sampleSsh,
  loadSecrets: () async => const SshSecrets(password: 'pw'),
  transportFactory: (params, verify) async => transport,
);

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      sshSessionServiceProvider.overrideWith(
        (ref, host) => _service(host == _lab ? _labTransport! : _pcTransport!),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

_Transport? _labTransport;
_Transport? _pcTransport;

/// Keeps an autoDispose provider alive for the whole test.
void _keep(ProviderContainer container, HostRef host) {
  addTearDown(container.listen(sftpProvider(host), (_, _) {}).close);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an empty upload still creates or truncates the remote file', () async {
    final files = _Files();
    final transport = _Transport(files);
    _labTransport = transport;
    final container = _container();
    _keep(container, _lab);
    final sftp = container.read(sftpProvider(_lab).notifier);
    await sftp.connect();

    final dir = await Directory.systemTemp.createTemp('sftp-empty-');
    addTearDown(() => dir.delete(recursive: true));
    final empty = File('${dir.path}/empty.txt')..writeAsBytesSync(const []);
    files.bytes['/srv/empty.txt'] = Uint8List.fromList('old content'.codeUnits);

    await sftp.upload(localPath: empty.path, remoteDir: '/srv');
    expect(
      files.writes,
      [('/srv/empty.txt', 0, 0, true)],
      reason: '空文件也要发一次 create+truncate，否则远端没有文件、覆盖时旧内容还在',
    );
    expect(files.bytes['/srv/empty.txt'], isEmpty, reason: '覆盖空文件必须清掉旧内容');
    expect(container.read(sftpProvider(_lab)).transfers.single.status, SftpTransferStatus.done);
  });

  test('cancelling during the final upload chunk reports cancelled, never done', () async {
    final files = _Files(gateWriteAt: 1); // second (final) 64 KiB chunk of ~128 KiB
    final transport = _Transport(files);
    _labTransport = transport;
    final container = _container();
    _keep(container, _lab);
    final sftp = container.read(sftpProvider(_lab).notifier);
    await sftp.connect();

    final dir = await Directory.systemTemp.createTemp('sftp-cancel-');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/two-chunks.bin')..writeAsBytesSync(List.filled(128 * 1024, 7));

    final future = sftp.upload(localPath: source.path, remoteDir: '/srv');
    for (var i = 0; i < 200 && (files.writeGate == null); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(files.writes, hasLength(1), reason: '第一块已写、最后一块被挡住');
    final transfer = container.read(sftpProvider(_lab)).transfers.single;
    sftp.cancel(transfer.id);
    files.writeGate!.complete();
    await future;

    expect(
      container.read(sftpProvider(_lab)).transfers.single.status,
      SftpTransferStatus.cancelled,
      reason: '最后一块期间取消不能最终显示完成',
    );
  });

  test('cancelling during the final download chunk reports cancelled, never done', () async {
    final files = _Files()..bytes['/srv/big.bin'] = Uint8List.fromList(List.filled(600 * 1024, 5));
    files.gateReadOffset = 512 * 1024; // the last 88 KiB chunk
    final transport = _Transport(files);
    _labTransport = transport;
    final container = _container();
    _keep(container, _lab);
    final sftp = container.read(sftpProvider(_lab).notifier);
    await sftp.connect(path: '/srv');

    final dir = await Directory.systemTemp.createTemp('sftp-dl-cancel-');
    addTearDown(() => dir.delete(recursive: true));
    final target = '${dir.path}/big.bin';
    final future = sftp.download(remotePath: '/srv/big.bin', localPath: target);
    for (var i = 0; i < 500 && files.readGate == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final transfer = container.read(sftpProvider(_lab)).transfers.single;
    expect(transfer.done, 512 * 1024, reason: '前两块已写，最后一块被挡住');
    sftp.cancel(transfer.id);
    files.readGate!.complete();
    await future;

    expect(
      container.read(sftpProvider(_lab)).transfers.single.status,
      SftpTransferStatus.cancelled,
      reason: '最后一块期间取消不能最终显示完成',
    );
  });

  test('a permission failure keeps its kind instead of becoming a generic error', () async {
    final files = _Files()..chmodError = const SftpFailure(SftpFailureKind.permissionDenied);
    final transport = _Transport(files);
    _labTransport = transport;
    final container = _container();
    _keep(container, _lab);
    final sftp = container.read(sftpProvider(_lab).notifier);
    await sftp.connect();

    await expectLater(
      sftp.chmod('/srv/app.txt', 0x180),
      throwsA(isA<SftpFailure>().having((f) => f.kind, 'kind', SftpFailureKind.permissionDenied)),
    );
    expect(files.chmods, isEmpty);
    expect(container.read(sftpProvider(_lab)).phase, SftpPhase.ready);
  });

  test('copy streams one file in 256 KiB windows to the exact target', () async {
    final files = _Files()..bytes['/srv/big.bin'] = Uint8List.fromList(List.filled(600 * 1024, 9));
    final transport = _Transport(files);
    _labTransport = transport;
    final container = _container();
    _keep(container, _lab);
    final sftp = container.read(sftpProvider(_lab).notifier);
    await sftp.connect();

    await sftp.copy(from: '/srv/big.bin', to: '/backup/big.bin');
    expect(files.bytes['/backup/big.bin'], hasLength(600 * 1024));
    final copied = [for (final w in files.writes) if (w.$1 == '/backup/big.bin') w];
    expect(copied.first.$2, 0);
    expect(copied.first.$4, isTrue);
    expect([for (final w in copied) w.$2], orderedEquals([for (final w in copied) w.$2]..sort()));
    expect(copied.length, greaterThan(1), reason: '按窗口流式复制，不整文件进内存');

    files.dirs.add('/srv/project');
    await expectLater(
      sftp.copy(from: '/srv/project', to: '/backup/project'),
      throwsA(isA<SftpFailure>().having((f) => f.kind, 'kind', SftpFailureKind.unsupported)),
    );
  });

  test('copying a symlinked directory is refused instead of walking into it', () async {
    final files = _Files();
    files.dirs.add('/srv/real-dir');
    files.symlinks.add('/srv/link-dir');
    files.symlinkTarget['/srv/link-dir'] = '/srv/real-dir';
    final transport = _Transport(files);
    _labTransport = transport;
    final container = _container();
    _keep(container, _lab);
    final sftp = container.read(sftpProvider(_lab).notifier);
    await sftp.connect();

    final before = files.writes.length;
    await expectLater(
      sftp.copy(from: '/srv/link-dir', to: '/backup/link-dir'),
      throwsA(isA<SftpFailure>().having((f) => f.kind, 'kind', SftpFailureKind.unsupported)),
    );
    expect(files.writes.length, before, reason: '不得把链接目录当普通目录复制');
  });

  test('a move is one server-side rename and a symlink moves as itself', () async {
    final files = _Files()..bytes['/srv/a.txt'] = Uint8List.fromList('a'.codeUnits);
    files.symlinks.add('/srv/link.txt');
    final transport = _Transport(files);
    _labTransport = transport;
    final container = _container();
    _keep(container, _lab);
    final sftp = container.read(sftpProvider(_lab).notifier);
    await sftp.connect();

    await sftp.move(from: '/srv/a.txt', to: '/backup/a.txt');
    await sftp.move(from: '/srv/link.txt', to: '/backup/link.txt');
    expect(files.renames, [('/srv/a.txt', '/backup/a.txt'), ('/srv/link.txt', '/backup/link.txt')]);
    expect(files.writes, isEmpty, reason: '移动只 rename，不读内容');
  });

  test('copy and move keep a permission failure kind', () async {
    final files = _Files()..bytes['/srv/a.txt'] = Uint8List.fromList('a'.codeUnits);
    files.writeError = const SftpFailure(SftpFailureKind.permissionDenied);
    final transport = _Transport(files);
    _labTransport = transport;
    final container = _container();
    _keep(container, _lab);
    final sftp = container.read(sftpProvider(_lab).notifier);
    await sftp.connect();

    await expectLater(
      sftp.copy(from: '/srv/a.txt', to: '/backup/a.txt'),
      throwsA(isA<SftpFailure>().having((f) => f.kind, 'kind', SftpFailureKind.permissionDenied)),
    );
  });

  test('two files with the same name on one host download to separate scratch files', () async {
    final files = _Files()
      ..bytes['/a/readme.txt'] = Uint8List.fromList('first host file'.codeUnits)
      ..bytes['/b/readme.txt'] = Uint8List.fromList('second file'.codeUnits);
    final transport = _Transport(files);
    _labTransport = transport;
    final container = _container();
    _keep(container, _lab);
    final sftp = container.read(sftpProvider(_lab).notifier);
    await sftp.connect();

    final root = await Directory.systemTemp.createTemp('sftp-same-name-');
    addTearDown(() => root.delete(recursive: true));
    final previous = PathProviderPlatform.instance;
    addTearDown(() => PathProviderPlatform.instance = previous);
    useTempRoot(root.path);

    final one = await sftpTempPath(_lab, '/a/readme.txt');
    final two = await sftpTempPath(_lab, '/b/readme.txt');
    expect(one, isNot(two), reason: '同一台主机的同名文件不能共用一个临时路径');
    expect(Directory(one).parent.path, isNot(Directory(two).parent.path), reason: '每次下载一个独立子目录');
    expect(one, endsWith('/readme.txt'), reason: '保留原文件名给预览和分享');
    expect(two, endsWith('/readme.txt'));

    // Both in flight at once: neither download may land on the other's bytes.
    await Future.wait([
      sftp.download(remotePath: '/a/readme.txt', localPath: one),
      sftp.download(remotePath: '/b/readme.txt', localPath: two),
    ]);

    expect(File(one).readAsStringSync(), 'first host file');
    expect(File(two).readAsStringSync(), 'second file');
    expect(
      container.read(sftpProvider(_lab)).transfers.map((t) => t.status),
      everyElement(SftpTransferStatus.done),
    );
  });

  test('two hosts keep separate sessions, state and failures', () async {
    final labFiles = _Files()..bytes['/srv/lab.txt'] = Uint8List.fromList('lab'.codeUnits);
    final pcFiles = _Files()..bytes['/home/pc.txt'] = Uint8List.fromList('pc'.codeUnits);
    final lab = _Transport(labFiles);
    final pc = _Transport(pcFiles);
    _labTransport = lab;
    _pcTransport = pc;
    final container = _container();
    _keep(container, _lab);
    _keep(container, _pc);

    final labSftp = container.read(sftpProvider(_lab).notifier);
    final pcSftp = container.read(sftpProvider(_pc).notifier);
    await labSftp.connect(path: '/srv');
    await pcSftp.connect(path: '/home');

    expect([for (final e in container.read(sftpProvider(_lab)).entries) e.name], ['lab.txt']);
    expect([for (final e in container.read(sftpProvider(_pc)).entries) e.name], ['pc.txt']);

    await labSftp.remove('/srv/lab.txt', directory: false);
    expect(labFiles.removes, ['/srv/lab.txt']);
    expect(pcFiles.removes, isEmpty, reason: '一台主机的操作不得落到另一台');

    lab.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(sftpProvider(_lab)).phase, SftpPhase.failed);
    expect(container.read(sftpProvider(_pc)).phase, SftpPhase.ready, reason: '一台断线不影响另一台');
  });
}
