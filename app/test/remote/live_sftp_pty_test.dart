// Live SFTP and PTY checks against the throwaway sshd fixture: file transfer,
// permission bits, symlinks, an interactive shell with window resizing, and
// what happens to those sessions when the SSH connection drops. The fixture
// starts no DSH at all — nothing here needs the engine, a tunnel or a DSH
// token, which is the "DSH 不运行仍可用" case.
//
//   bash tooling/ios/tests/ssh-live/with-sshd.sh -- \
//     flutter test --no-pub test/remote/live_sftp_pty_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_session_capabilities.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final env = Platform.environment;
  final port = int.tryParse(env['DSH_APP_LIVE_SSHD_PORT'] ?? '');
  final keyPath = env['DSH_APP_LIVE_SSHD_KEY'];
  final user = env['DSH_APP_LIVE_SSHD_USER'];
  final work = env['DSH_APP_LIVE_SSHD_WORK'];
  final enabled = port != null && keyPath != null && user != null && work != null;
  final skip = enabled ? false : 'run through tooling/ios/tests/ssh-live/with-sshd.sh';
  // A pty needs an allocatable /dev/pts. The fixture probes it: on a host where
  // devpts is read-only the unprivileged sshd refuses the pty and closes the
  // connection, so PTY runs only where the fixture says it works.
  final ptyAvailable = env['DSH_APP_LIVE_SSHD_PTY'] == '1';
  final ptySkip = !enabled
      ? skip
      : ptyAvailable
      ? false
      : 'this host cannot allocate a pty (devpts is read-only); run where sshd may allocate one';
  final livePort = port ?? 0;
  final liveUser = user ?? '';
  final liveWork = work ?? '';

  late String clientKey;
  setUpAll(() {
    if (enabled) clientKey = File(keyPath).readAsStringSync();
  });

  Future<SshTransport> connect() => DartSshTransport.connect(
    SshConnectParams(
      host: '127.0.0.1',
      port: livePort,
      username: liveUser,
      auth: SshAuthMethod.privateKey,
      secrets: SshSecrets(privateKey: clientKey),
      connectTimeout: const Duration(seconds: 15),
    ),
    (_) => true,
  );

  /// One connected transport plus an SFTP session, both torn down.
  Future<(SshTransport, SshFileSession)> connectSftp() async {
    final transport = await connect();
    addTearDown(transport.close);
    final sftp = await (transport as SshSessionHost).openSftp();
    addTearDown(sftp.close);
    return (transport, sftp);
  }

  test('SFTP transfers a file and reports its stat', () async {
    final (_, sftp) = await connectSftp();
    final path = '$liveWork/sftp-roundtrip.txt';
    final payload = utf8.encode('hello sftp');
    await sftp.writeRange(path, Uint8List.fromList(payload), truncate: true);

    expect(utf8.decode(await sftp.readRange(path)), 'hello sftp');
    expect(utf8.decode(await sftp.readRange(path, offset: 6, length: 4)), 'sftp');
    final stat = await sftp.stat(path);
    expect(stat.isRegularFile, isTrue);
    expect(stat.isDirectory, isFalse);
    expect(stat.size, payload.length);
    expect(stat.modified, isNotNull);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('SFTP overwrite, append and rename land on the server', () async {
    final (_, sftp) = await connectSftp();
    final a = '$liveWork/sftp-edit-a.txt';
    final b = '$liveWork/sftp-edit-b.txt';
    await sftp.writeRange(a, Uint8List.fromList(utf8.encode('0123456789')), truncate: true);
    await sftp.writeRange(a, Uint8List.fromList(utf8.encode('AA')), offset: 2);
    await sftp.writeRange(a, Uint8List.fromList(utf8.encode('-tail')), append: true);
    expect(utf8.decode(await sftp.readRange(a)), '01AA456789-tail');

    await sftp.rename(a, b);
    final names = [for (final e in await sftp.list(liveWork)) e.name];
    expect(names, contains('sftp-edit-b.txt'));
    expect(names, isNot(contains('sftp-edit-a.txt')));
    await sftp.remove(b);
    expect([for (final e in await sftp.list(liveWork)) e.name], isNot(contains('sftp-edit-b.txt')));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('SFTP permission bits round-trip through chmod and stat', () async {
    final (_, sftp) = await connectSftp();
    final path = '$liveWork/sftp-perms.txt';
    await sftp.writeRange(path, Uint8List.fromList(utf8.encode('x')), truncate: true);

    await sftp.chmod(path, 0x1A0); // 0o640
    expect((await sftp.stat(path)).mode, 0x1A0);
    await sftp.chmod(path, 0x1ED); // 0o755
    expect((await sftp.stat(path)).mode, 0x1ED);
    await sftp.remove(path);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('a symlink is listed as such and resolves only when followed', () async {
    final (transport, sftp) = await connectSftp();
    final target = '$liveWork/sftp-link-target.txt';
    final link = '$liveWork/sftp-link.txt';
    await sftp.writeRange(target, Uint8List.fromList(utf8.encode('linked')), truncate: true);
    final made = await transport.run('ln -sf $target $link');
    expect(made.exitCode, 0, reason: made.stderr);

    final entry = (await sftp.list(liveWork)).firstWhere((e) => e.name == 'sftp-link.txt');
    expect(entry.isSymbolicLink, isTrue);

    final asLink = await sftp.stat(link, followLinks: false);
    expect(asLink.isSymbolicLink, isTrue);
    expect(asLink.isRegularFile, isFalse);
    final asTarget = await sftp.stat(link);
    expect(asTarget.isSymbolicLink, isFalse);
    expect(asTarget.isRegularFile, isTrue);
    expect(utf8.decode(await sftp.readRange(link)), 'linked');

    await sftp.remove(link);
    await sftp.remove(target);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('SFTP makes and removes a directory and resolves absolute paths', () async {
    final (_, sftp) = await connectSftp();
    final dir = '$liveWork/sftp-dir';
    await sftp.makeDirectory(dir);
    final stat = await sftp.stat(dir);
    expect(stat.isDirectory, isTrue);
    final absolute = await sftp.absolute('$dir/../sftp-dir');
    expect(absolute, endsWith('/sftp-dir'));
    await sftp.remove(dir, directory: true);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('PTY holds its window size, follows a resize and returns the exit status', () async {
    final transport = await connect();
    addTearDown(transport.close);
    final session = await (transport as SshSessionHost).openPty(
      const SshPtyOptions(term: 'xterm-256color', columns: 100, rows: 40),
    );

    final output = BytesBuilder();
    final sub = session.output.listen(output.add, onError: (Object _) {});
    addTearDown(sub.cancel);
    String text() => utf8.decode(output.toBytes(), allowMalformed: true);
    Future<void> waitFor(String needle) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!text().contains(needle)) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for "$needle"; output so far:\n${text()}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    session.write(utf8.encode('stty size\n'));
    await waitFor('40 100');

    session.resize(columns: 120, rows: 30);
    session.write(utf8.encode('printf "after-resize:"; stty size\n'));
    await waitFor('after-resize:30 120');

    session.write(utf8.encode('exit 7\n'));
    expect(await session.exitCode.timeout(const Duration(seconds: 15)), 7);
    await session.done.timeout(const Duration(seconds: 15));
  }, skip: ptySkip, timeout: const Timeout(Duration(minutes: 1)));

  test('a dropped connection ends the open PTY', () async {
    final transport = await connect();
    final session = await (transport as SshSessionHost).openPty();
    final ended = Completer<void>();
    final sub = session.output.listen(
      (_) {},
      onError: (Object _) {},
      onDone: () {
        if (!ended.isCompleted) ended.complete();
      },
    );
    addTearDown(sub.cancel);

    transport.close();
    await Future.any([ended.future, session.done.catchError((Object _) {})]).timeout(
      const Duration(seconds: 15),
    );
    expect((transport as SshSessionHost).supportsSftp, isFalse);
  }, skip: ptySkip, timeout: const Timeout(Duration(minutes: 1)));

  test('closing an SFTP session leaves the SSH connection usable', () async {
    final transport = await connect();
    addTearDown(transport.close);
    final sessions = transport as SshSessionHost;
    final sftp = await sessions.openSftp();
    expect(await sftp.absolute(liveWork), contains(liveWork));
    await sftp.close();

    final result = await transport.run('printf still-alive');
    expect(result.stdout, 'still-alive');
    expect(result.exitCode, 0);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  // 已知缺陷（待 Flutter 处理）：连接在 PTY 打开时被关闭，dartssh2 销毁通道
  // 会在测试 zone 抛未捕获的 SSHStateError(SSH connection closed)，无法在测试
}
