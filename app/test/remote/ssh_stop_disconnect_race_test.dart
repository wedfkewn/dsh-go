// A network drop while the stop command is in flight must not let the
// reconnect loop start a fresh managed instance: the stop decision is taken
// before the round trip, so recovery stays blocked and only an explicit
// retry/restart brings the instance back.

import 'dart:async';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/remote_shell.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';

/// Holds the stop command open, kills the fake process first, and lets the
/// test drop the connection before the response arrives.
class _SlowStopTransport extends FakeTransport {
  _SlowStopTransport(super.remote, {required this.stopStarted, required this.releaseStop});

  final Completer<void> stopStarted;
  final Completer<void> releaseStop;

  @override
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)}) async {
    // Only RemoteDshBootstrap.stop() sends pkill/kill; the probe uses kill -0.
    if (script.contains('pkill -TERM')) {
      remote.pid = null; // the kill landed; the stop response is still in flight
      if (!stopStarted.isCompleted) stopStarted.complete();
      await releaseStop.future;
    }
    return super.run(script, timeout: timeout);
  }
}

Backoff _quick() =>
    Backoff(initial: const Duration(milliseconds: 10), max: const Duration(milliseconds: 40), maxAttempts: 2);

void main() {
  late FakeSshServer server;
  late FakeConnector connector;
  late Completer<void> stopStarted;
  late Completer<void> releaseStop;

  setUp(() {
    server = FakeSshServer();
    connector = FakeConnector();
    stopStarted = Completer<void>();
    releaseStop = Completer<void>();
  });

  test('a drop during stopManaged does not reconnect or start a second instance', () async {
    final link = SshHostLink(
      config: sampleSsh,
      loadSecrets: () async => const SshSecrets(password: 'pw'),
      transportFactory: (params, verify) async {
        if (!await verify(server.hostKey)) {
          throw const HostLinkError(HostLinkErrorKind.hostKeyRejected, 'rejected');
        }
        final transport = _SlowStopTransport(
          server.remote,
          stopStarted: stopStarted,
          releaseStop: releaseStop,
        );
        server.transports.add(transport);
        return transport;
      },
      connectClient: connector.call,
      backoff: _quick(),
    );
    addTearDown(link.close);

    await link.open();
    expect(server.remote.launches, 1);
    expect(link.status.phase, HostLinkPhase.connected);

    final stopping = link.stopManaged();
    await stopStarted.future.timeout(const Duration(seconds: 5));

    // The link dies before the stop response arrives.
    link.debugDropTransport();
    releaseStop.complete();
    await expectLater(stopping, throwsA(isA<HostLinkError>()));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(link.stoppedByUser, isTrue);
    expect(link.status.phase, HostLinkPhase.failed);
    expect(server.transports, hasLength(1), reason: 'the stop must not open a second connection');
    expect(server.remote.launches, 1, reason: 'the stop must not start a second instance');
  });
}
