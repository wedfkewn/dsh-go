// Live SSH transport checks against a throwaway sshd on loopback:
// host-key preflight, fingerprint comparison, key auth (plain and
// passphrase), rejected keys, and direct-tcpip forwarding. Opt-in through the
// fixture, which sets all the inputs:
//
//   bash tooling/ios/tests/ssh-live/with-sshd.sh -- \
//     flutter test test/remote/live_ssh_transport_test.dart
//
// The fixture listens on 127.0.0.1 only, generates its own host/client keys in
// a temp directory, and disables password and PAM auth. Nothing under ~/.ssh is
// read or written, and no DSH process is started.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final env = Platform.environment;
  final port = int.tryParse(env['DSH_APP_LIVE_SSHD_PORT'] ?? '');
  final keyPath = env['DSH_APP_LIVE_SSHD_KEY'];
  final hostPubPath = env['DSH_APP_LIVE_SSHD_HOST_PUB'];
  final user = env['DSH_APP_LIVE_SSHD_USER'];
  final passKeyPath = env['DSH_APP_LIVE_SSHD_PASS_KEY'];
  final passphrase = env['DSH_APP_LIVE_SSHD_PASSPHRASE'] ?? '';
  final enabled = port != null && keyPath != null && user != null && passKeyPath != null;
  final skip = enabled ? false : 'run through tooling/ios/tests/ssh-live/with-sshd.sh';
  // Non-null inputs for the bodies; every test is skipped when they are absent.
  final livePort = port ?? 0;
  final liveUser = user ?? '';
  final liveKeyPath = keyPath ?? '';
  final livePassKeyPath = passKeyPath ?? '';
  final liveHostPub = hostPubPath ?? '';

  SshConnectParams paramsWith(String key, {String? passphrase}) => SshConnectParams(
    host: '127.0.0.1',
    port: livePort,
    username: liveUser,
    auth: SshAuthMethod.privateKey,
    secrets: SshSecrets(privateKey: key, passphrase: passphrase),
    connectTimeout: const Duration(seconds: 15),
  );

  late String clientKey;
  setUpAll(() {
    if (enabled) clientKey = File(liveKeyPath).readAsStringSync();
  });

  test('host key preflight matches ssh-keygen without logging in', () async {
    final seen = await fetchHostKey(
      SshHostConfig(id: 'ssh-live', name: 'live', host: '127.0.0.1', port: livePort, user: liveUser),
    );
    expect(seen.type, 'ssh-ed25519');
    expect(seen.shortType, 'ED25519');
    final fingerprint = Process.runSync('ssh-keygen', ['-lf', liveHostPub]).stdout.toString().trim().split(' ')[1];
    expect(seen.fingerprint, fingerprint);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('a rejected host key fails closed before authentication', () async {
    await expectLater(
      DartSshTransport.connect(paramsWith(clientKey), (_) => false),
      throwsA(isA<HostLinkError>().having((e) => e.kind, 'kind', HostLinkErrorKind.hostKeyRejected)),
    );
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('private key auth runs a command on the remote', () async {
    final seen = <PresentedHostKey>[];
    final transport = await DartSshTransport.connect(paramsWith(clientKey), (key) {
      seen.add(key);
      return key.type == 'ssh-ed25519';
    });
    addTearDown(transport.close);
    expect(seen, hasLength(1));
    final result = await transport.run('printf live-ok', timeout: const Duration(seconds: 20));
    expect(result.exitCode, 0);
    expect(result.stdout, 'live-ok');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('passphrase-protected private key authenticates', () async {
    final transport = await DartSshTransport.connect(
      paramsWith(File(livePassKeyPath).readAsStringSync(), passphrase: passphrase),
      (_) => true,
    );
    addTearDown(transport.close);
    final result = await transport.run('printf passphrase-ok', timeout: const Duration(seconds: 20));
    expect(result.stdout, 'passphrase-ok');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('an unauthorized key is an auth failure, not a retry', () async {
    final dir = Directory.systemTemp.createTempSync('dsh-live-unauthorized-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final keyFile = File('${dir.path}/id_ed25519');
    final generated = Process.runSync('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', keyFile.path]);
    expect(generated.exitCode, 0, reason: generated.stderr.toString());
    await expectLater(
      DartSshTransport.connect(paramsWith(keyFile.readAsStringSync()), (_) => true),
      throwsA(isA<HostLinkError>().having((e) => e.kind, 'kind', HostLinkErrorKind.authFailed)),
    );
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('direct-tcpip reaches a loopback HTTP server through the tunnel', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..statusCode = 200
        ..write('tunnel-ok');
      unawaited(request.response.close());
    });

    final transport = await DartSshTransport.connect(paramsWith(clientKey), (_) => true);
    addTearDown(transport.close);
    final channel = await transport.openTunnel('127.0.0.1', server.port);
    final body = StringBuffer();
    final done = Completer<void>();
    final subscription = channel.stream.listen(
      (data) => body.write(utf8.decode(data)),
      onDone: done.complete,
      onError: done.completeError,
    );
    channel.sink.add(utf8.encode('GET / HTTP/1.1\r\nHost: live\r\nConnection: close\r\n\r\n'));
    await done.future.timeout(const Duration(seconds: 10));
    await subscription.cancel();
    channel.destroy();

    expect(body.toString(), contains('200 OK'));
    expect(body.toString(), contains('tunnel-ok'));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));
}
