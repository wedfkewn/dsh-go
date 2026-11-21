// Stopping a managed DSH is a decision: no automatic path (keepalive loss,
// network kick, a page rebuilding) may start it again. Only an explicit
// retry/restart does. Attach-only has no managed instance to stop.

import 'dart:async';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';
import 'support/wait.dart';

Backoff _quick() =>
    Backoff(initial: const Duration(milliseconds: 10), max: const Duration(milliseconds: 40), maxAttempts: 2);

void main() {
  late FakeSshServer server;
  late FakeConnector connector;
  final links = <SshHostLink>[];

  setUp(() {
    server = FakeSshServer();
    connector = FakeConnector();
  });

  tearDown(() async {
    for (final link in links) {
      await link.close();
    }
    links.clear();
  });

  SshHostLink link({SshHostConfig config = sampleSsh, StreamController<void>? kicks}) {
    final l = SshHostLink(
      config: config,
      loadSecrets: () async => const SshSecrets(password: 'pw'),
      transportFactory: server.connect,
      connectClient: connector.call,
      backoff: _quick(),
      kicks: kicks?.stream,
      keepAliveInterval: const Duration(milliseconds: 20),
      keepAliveTimeout: const Duration(milliseconds: 20),
    );
    links.add(l);
    return l;
  }

  test('after stopManaged no automatic path reconnects or restarts the instance', () async {
    final kicks = StreamController<void>.broadcast(sync: true);
    addTearDown(kicks.close);
    final l = link(kicks: kicks);
    await l.open();
    expect(server.remote.launches, 1);
    expect(l.ownership, SshDshOwnership.managedStarted);

    await l.stopManaged();
    expect(l.stoppedByUser, isTrue);
    expect(l.status.phase, HostLinkPhase.failed);
    expect(server.remote.launches, 1);
    final transportsAfterStop = server.transports.length;

    // Paths that are not an explicit decision must stay put.
    kicks.add(null); // network changed
    l.kick(); // status row / drawer refresh
    await expectLater(l.open(), throwsA(isA<HostLinkError>()));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.transports.length, transportsAfterStop, reason: 'no transport may be opened after a stop');
    expect(server.remote.launches, 1, reason: 'no process may be started after a stop');
    expect(l.status.phase, HostLinkPhase.failed);

    // An explicit retry is the way back; the fake instance is still alive, so
    // it reconnects without starting a second process.
    final reconnected = nextStatus(l, (s) => s.isConnected, what: '显式重连');
    l.retry();
    await reconnected;
    expect(server.remote.launches, 1);
    expect(l.ownership, SshDshOwnership.managedReused);
  });
}
