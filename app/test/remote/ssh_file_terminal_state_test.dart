// Smoke tests for the DSH-independent file/terminal layer: the service opens
// its own SSH connection, SFTP lists and streams, a transfer stops on cancel,
// terminal bytes printed before the page subscribes are kept, and a lost
// connection ends everything without replaying anything.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHChannelRequestError, SSHStateError;
import 'package:dsh_app/remote/ssh/ssh_session_capabilities.dart';
import 'package:dsh_app/remote/ssh/ssh_session_service.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:dsh_app/remote/ssh/remote_shell.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sftp_state.dart';
import 'package:dsh_app/state/ssh_session_state.dart';
import 'package:dsh_app/state/ssh_terminal_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';

/// autoDispose providers die without a listener; pages hold one, tests too.
void keepSftp(ProviderContainer container) {
  addTearDown(container.listen(sftpProvider(HostRef.ssh('pc')), (_, _) {}).close);
}

void keepTerminals(ProviderContainer container) {
  addTearDown(container.listen(sshTerminalsProvider(HostRef.ssh('pc')), (_, _) {}).close);
}

Future<void> settle([int turns = 12]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FakeFiles implements SshFileSession {
  FakeFiles();

  final Map<String, Uint8List> bytes = {};
  final Map<String, String> parents = {};
  final List<String> entries = [];

  /// Per-directory listings for tree tests (search, listDir). A directory that
  /// is absent here falls back to [entries].
  final Map<String, List<SshFileEntry>> listing = {};
  final List<(String, int)> writes = [];
  Future<void> Function(int offset)? beforeRead;
  Future<void> Function(int offset)? beforeWrite;
  bool closed = false;

  @override
  Future<List<SshFileEntry>> list(String path) async {
    final tree = listing[path];
    if (tree != null) return tree;
    return [
      for (final name in entries)
        SshFileEntry(
          name: name,
          isDirectory: !name.contains('.'),
          isSymbolicLink: false,
          size: bytes['$path/$name']?.length,
          modified: null,
          mode: 0x1A4,
        ),
    ];
  }

  @override
  Future<SshFileStat> stat(String path, {bool followLinks = true}) async {
    final data = bytes[path];
    return SshFileStat(
      isDirectory: data == null,
      isSymbolicLink: false,
      isRegularFile: data != null,
      size: data?.length,
      modified: null,
      mode: 0x1A4,
    );
  }

  @override
  Future<Uint8List> readRange(String path, {int offset = 0, int? length}) async {
    await beforeRead?.call(offset);
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
    await beforeWrite?.call(offset);
    writes.add((path, offset));
    final existing = truncate || !bytes.containsKey(path) ? Uint8List(0) : bytes[path]!;
    final out = Uint8List(existing.length > offset ? existing.length : offset + data.length);
    out.setRange(0, existing.length, existing);
    out.setRange(offset, offset + data.length, data);
    bytes[path] = out;
  }

  @override
  Future<void> makeDirectory(String path) async {}
  @override
  Future<void> remove(String path, {bool directory = false}) async {}
  @override
  Future<void> rename(String from, String to) async {
    final data = bytes.remove(from);
    if (data != null) bytes[to] = data;
  }
  @override
  Future<void> chmod(String path, int mode) async {}
  @override
  Future<String> absolute(String path) async => path;
  @override
  Future<void> close() async => closed = true;
}

class FakePty implements SshPtySession {
  final _out = StreamController<Uint8List>.broadcast();
  final List<String> written = [];
  final List<(int, int)> sizes = [];
  final _exit = Completer<int?>();
  var closed = false;

  void emit(String text) => _out.add(Uint8List.fromList(text.codeUnits));

  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  void write(List<int> data) => written.add(String.fromCharCodes(data));
  @override
  void resize({required int columns, required int rows}) => sizes.add((columns, rows));
  @override
  Future<int?> get exitCode => _exit.future;
  @override
  Future<void> get done => _out.stream.drain<void>();
  @override
  void close() {
    if (closed) return;
    closed = true;
    if (!_exit.isCompleted) _exit.complete(null);
    unawaited(_out.close());
  }
}

class FakeTransport implements SshTransport, SshSessionHost {
  FakeTransport(this.files);

  final FakeFiles files;
  final _done = Completer<void>();
  final FakePty? pty = FakePty();
  var closed = false;
  var connects = 0;

  /// Set to make the next [openPty] fail the way a server that refuses a pty,
  /// or a connection that dies during setup, fails it.
  Object? openPtyError;

  @override
  bool get supportsSftp => true;
  @override
  bool get supportsPty => true;
  @override
  Future<SshFileSession> openSftp() async => files;
  @override
  Future<SshPtySession> openPty([SshPtyOptions options = const SshPtyOptions()]) async {
    final error = openPtyError;
    if (error != null) throw error;
    return pty!;
  }

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

ProviderContainer containerFor(FakeTransport transport) {
  final container = ProviderContainer(
    overrides: [
      sshSessionServiceProvider.overrideWith(
        (ref, host) => SshSessionService(
          config: sampleSsh,
          loadSecrets: () async => const SshSecrets(password: 'pw'),
          transportFactory: (params, verify) async {
            transport.connects++;
            return transport;
          },
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SFTP lists the server directory without DSH and streams a download', () async {
    final files = FakeFiles()..entries.addAll(['beta', 'alpha', 'readme.txt']);
    files.bytes['/srv/readme.txt'] = Uint8List.fromList(List.filled(600 * 1024, 65));
    final transport = FakeTransport(files);
    final container = containerFor(transport);
    keepSftp(container);
    final sftp = container.read(sftpProvider(HostRef.ssh('pc')).notifier);

    await sftp.connect(path: '/srv');
    expect(sftp.state.phase, SftpPhase.ready);
    expect([for (final e in sftp.state.entries) e.name], ['alpha', 'beta', 'readme.txt']);

    final dir = await Directory.systemTemp.createTemp('sftp-dl-');
    addTearDown(() => dir.delete(recursive: true));
    final target = '${dir.path}/readme.txt';
    await sftp.download(remotePath: '/srv/readme.txt', localPath: target);
    expect(sftp.state.transfers.single.status, SftpTransferStatus.done);
    expect(sftp.state.transfers.single.done, 600 * 1024);
    expect(await File(target).length(), 600 * 1024);
  });

  test('a cancelled transfer stops and reports cancelled, not failed', () async {
    final files = FakeFiles();
    files.bytes['/big'] = Uint8List.fromList(List.filled(600 * 1024, 66));
    final gate = Completer<void>();
    files.beforeRead = (offset) async {
      if (offset > 0) await gate.future;
    };
    final transport = FakeTransport(files);
    final container = containerFor(transport);
    keepSftp(container);
    final sftp = container.read(sftpProvider(HostRef.ssh('pc')).notifier);
    await sftp.connect(path: '/');

    final dir = await Directory.systemTemp.createTemp('sftp-cancel-');
    addTearDown(() => dir.delete(recursive: true));
    final future = sftp.download(remotePath: '/big', localPath: '${dir.path}/big');
    for (var i = 0; i < 50 && (sftp.state.transfers.isEmpty || sftp.state.transfers.single.done == 0); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    sftp.cancel('xfer-0');
    gate.complete();
    await future;

    expect(sftp.state.transfers.single.status, SftpTransferStatus.cancelled);
  });

  test('terminal bytes printed before the page subscribes are kept, and input is not replayed', () async {
    final transport = FakeTransport(FakeFiles());
    final container = containerFor(transport);
    keepTerminals(container);
    final terminals = container.read(sshTerminalsProvider(HostRef.ssh('pc')).notifier);

    final id = await terminals.openTab(title: 'one');
    transport.pty!.emit('hello');
    final seen = <int>[];
    final sub = terminals.outputOf(id).listen((data) => seen.addAll(data));
    await settle();
    expect(seen, 'hello'.codeUnits);

    terminals.write(id, 'ls\n');
    terminals.resize(id, columns: 100, rows: 30);
    expect(transport.pty!.written, ['ls\n']);
    expect(transport.pty!.sizes, [(100, 30)]);

    await sub.cancel();
    await terminals.closeTab(id);
    expect(transport.pty!.closed, isTrue);
  });

  test('a pty that cannot be opened fails its tab only, and the page keeps working', () async {
    final transport = FakeTransport(FakeFiles());
    final container = containerFor(transport);
    keepTerminals(container);
    final terminals = container.read(sshTerminalsProvider(HostRef.ssh('pc')).notifier);
    // A connection that dies during pty setup, not a server that refuses one.
    transport.openPtyError = SSHStateError('SSH connection closed');

    final failed = await terminals.openTab(title: 'broken');
    expect(terminals.state.tabs.single.id, failed);
    expect(terminals.state.tabs.single.status, SshTabStatus.failed);
    expect(terminals.state.tabs.single.failure?.kind, SshFailureKind.connectionLost);
    expect(terminals.state.failure, isNull, reason: 'one refused shell is not a page failure');
    // A write to a tab whose shell never started is a no-op, not a crash.
    terminals.write(failed, 'ls\n');

    transport.openPtyError = null;
    final working = await terminals.openTab(title: 'second');
    expect(terminals.state.tabs.length, 2);
    expect(
      terminals.state.tabs.firstWhere((tab) => tab.id == working).status,
      SshTabStatus.running,
    );
    await terminals.closeTab(failed);
    await terminals.closeTab(working);
  });

  test('a server that refuses the pty reports ptyRefused, not a lost connection', () async {
    final transport = FakeTransport(FakeFiles());
    final container = containerFor(transport);
    keepTerminals(container);
    final terminals = container.read(sshTerminalsProvider(HostRef.ssh('pc')).notifier);
    transport.openPtyError = SSHChannelRequestError('Failed to start pty');

    final id = await terminals.openTab();
    expect(terminals.state.tabs.single.status, SshTabStatus.failed);
    expect(terminals.state.tabs.single.failure?.kind, SshFailureKind.ptyRefused);
    await terminals.closeTab(id);
  });

  test('upload streams the phone file in chunks instead of loading it whole', () async {
    final files = FakeFiles()..entries.add('big.bin');
    final transport = FakeTransport(files);
    final container = containerFor(transport);
    keepSftp(container);
    final sftp = container.read(sftpProvider(HostRef.ssh('pc')).notifier);
    await sftp.connect(path: '/srv');

    final dir = await Directory.systemTemp.createTemp('sftp-ul-');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/big.bin');
    final payload = List<int>.generate(600 * 1024, (i) => i & 0xFF);
    await source.writeAsBytes(payload);

    await sftp.upload(localPath: source.path, remoteDir: '/srv');

    expect(sftp.state.transfers.single.status, SftpTransferStatus.done);
    expect(sftp.state.transfers.single.done, payload.length);
    // More than one write, ascending offsets from 0: the file was read as a
    // stream, not turned into one buffer.
    expect(files.writes.length, greaterThan(1));
    expect(files.writes.first.$2, 0);
    for (var i = 1; i < files.writes.length; i++) {
      expect(files.writes[i].$2, greaterThan(files.writes[i - 1].$2));
    }
    expect(files.bytes['/srv/big.bin'], orderedEquals(payload));
  });


  test('an empty file upload creates the remote file, and overwrites one too', () async {
    final files = FakeFiles();
    final transport = FakeTransport(files);
    final container = containerFor(transport);
    keepSftp(container);
    final sftp = container.read(sftpProvider(HostRef.ssh('pc')).notifier);
    await sftp.connect(path: '/srv');

    final dir = await Directory.systemTemp.createTemp('sftp-empty-');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/empty.txt');
    await source.writeAsBytes(const <int>[]);

    await sftp.upload(localPath: source.path, remoteDir: '/srv');
    expect(files.bytes.containsKey('/srv/empty.txt'), isTrue, reason: 'an empty upload still creates the file');
    expect(files.bytes['/srv/empty.txt'], isEmpty);
    expect(sftp.state.transfers.single.status, SftpTransferStatus.done);
    expect(sftp.state.transfers.single.done, 0);

    files.bytes['/srv/empty.txt'] = Uint8List.fromList(utf8.encode('old content'));
    await sftp.upload(localPath: source.path, remoteDir: '/srv');
    expect(files.bytes['/srv/empty.txt'], isEmpty, reason: 'confirming overwrite with an empty file truncates it');
  });

  test('a cancel that lands while the last chunk is in flight ends cancelled, not done', () async {
    final files = FakeFiles();
    final gate = Completer<void>();
    files.beforeWrite = (offset) async => gate.future;
    final transport = FakeTransport(files);
    final container = containerFor(transport);
    keepSftp(container);
    final sftp = container.read(sftpProvider(HostRef.ssh('pc')).notifier);
    await sftp.connect(path: '/srv');

    final dir = await Directory.systemTemp.createTemp('sftp-last-');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/one.txt');
    await source.writeAsBytes(utf8.encode('one chunk only'));

    final future = sftp.upload(localPath: source.path, remoteDir: '/srv');
    for (var i = 0; i < 50 && sftp.state.transfers.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    sftp.cancel(sftp.state.transfers.single.id);
    gate.complete();
    await future;

    expect(sftp.state.transfers.single.status, SftpTransferStatus.cancelled);
  });

  test('copy, move, listDir and readBytes compose from the SFTP primitives', () async {
    final files = FakeFiles();
    files.bytes['/srv/a.txt'] = Uint8List.fromList(utf8.encode('hello'));
    files.listing['/srv'] = const [
      SshFileEntry(name: 'a.txt', isDirectory: false, isSymbolicLink: false, size: 5),
    ];
    final transport = FakeTransport(files);
    final container = containerFor(transport);
    keepSftp(container);
    final sftp = container.read(sftpProvider(HostRef.ssh('pc')).notifier);
    await sftp.connect(path: '/srv');

    expect(utf8.decode(await sftp.readBytes('/srv/a.txt')), 'hello');
    await expectLater(
      sftp.readBytes('/srv/a.txt', maxBytes: 2),
      throwsA(isA<SftpFailure>().having((f) => f.kind, 'kind', SftpFailureKind.tooLarge)),
    );

    final listed = await sftp.listDir('/srv');
    expect(listed.single.name, 'a.txt');
    expect(sftp.state.path, '/srv', reason: 'listDir must not move the browser');

    await sftp.copy(from: '/srv/a.txt', to: '/srv/b.txt');
    expect(utf8.decode(files.bytes['/srv/b.txt']!), 'hello');

    await sftp.move(from: '/srv/b.txt', to: '/srv/c.txt');
    expect(files.bytes.containsKey('/srv/b.txt'), isFalse);
    expect(utf8.decode(files.bytes['/srv/c.txt']!), 'hello');
  });

  test('search walks real directories, skips symlinked ones and hidden names on request', () async {
    final files = FakeFiles();
    files.listing['/'] = [
      SshFileEntry(name: 'alpha.txt', isDirectory: false, isSymbolicLink: false, size: 1),
      SshFileEntry(name: '.secret.txt', isDirectory: false, isSymbolicLink: false, size: 1),
      SshFileEntry(name: 'sub', isDirectory: true, isSymbolicLink: false),
      SshFileEntry(name: 'link', isDirectory: true, isSymbolicLink: true),
    ];
    files.listing['/sub'] = [
      SshFileEntry(name: 'alphabet.txt', isDirectory: false, isSymbolicLink: false, size: 1),
    ];
    // A hit behind the symlinked directory: entering it would be following a link.
    files.listing['/link'] = [
      SshFileEntry(name: 'alpha-hidden.txt', isDirectory: false, isSymbolicLink: false, size: 1),
    ];
    final transport = FakeTransport(files);
    final container = containerFor(transport);
    keepSftp(container);
    final sftp = container.read(sftpProvider(HostRef.ssh('pc')).notifier);
    await sftp.connect(path: '/');

    final found = await sftp.search('alpha');
    expect([for (final e in found) e.path], ['/alpha.txt', '/sub/alphabet.txt']);

    expect(await sftp.search('secret'), isEmpty);
    final hidden = await sftp.search('secret', includeHidden: true);
    expect([for (final e in hidden) e.path], ['/.secret.txt']);

    sftp.clearSearch();
    expect(sftp.state.searchResults, isEmpty);
  });

  test('a failed transfer waits for an explicit retry and keeps its id', () async {
    final files = FakeFiles();
    final transport = FakeTransport(files);
    final container = containerFor(transport);
    keepSftp(container);
    final sftp = container.read(sftpProvider(HostRef.ssh('pc')).notifier);
    await sftp.connect(path: '/srv');

    final dir = await Directory.systemTemp.createTemp('sftp-retry-');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/later.txt');

    // The file does not exist yet: no automatic retry, no replay, just failed.
    await sftp.upload(localPath: source.path, remoteDir: '/srv');
    final id = sftp.state.transfers.single.id;
    expect(sftp.state.transfers.single.status, SftpTransferStatus.failed);
    expect(files.writes, isEmpty);

    await source.writeAsBytes(utf8.encode('now it exists'));
    await sftp.retryTransfer(id);

    expect(sftp.state.transfers.single.id, id, reason: 'the retried row keeps the id the page watches');
    expect(sftp.state.transfers.single.status, SftpTransferStatus.done);
    expect(utf8.decode(files.bytes['/srv/later.txt']!), 'now it exists');
  });

  test('a lost connection ends the terminal and fails SFTP without reconnecting or replaying', () async {
    final transport = FakeTransport(FakeFiles()..entries.add('a'));
    final container = containerFor(transport);
    keepSftp(container);
    keepTerminals(container);
    final sftp = container.read(sftpProvider(HostRef.ssh('pc')).notifier);
    final terminals = container.read(sshTerminalsProvider(HostRef.ssh('pc')).notifier);

    await sftp.connect(path: '/');
    final id = await terminals.openTab();
    await sftp.download(remotePath: '/x', localPath: '/tmp/none');
    terminals.write(id, 'typed-before-loss');

    transport.close();
    await settle();

    expect(sftp.state.phase, SftpPhase.failed);
    expect(sftp.state.failure?.kind, SftpFailureKind.connectionLost);
    expect(terminals.state.tabs.single.status, SshTabStatus.ended);
    expect(terminals.state.tabs.single.failure?.kind, SshFailureKind.connectionLost);
    expect(transport.connects, 1, reason: 'a loss must not silently reconnect');
    expect(transport.pty!.written, ['typed-before-loss']);
  });
}
