// Attach mode never touches the remote DSH process: no probe, no start, no
// stop/restart entry. It only opens the fixed loopback tunnel the user pointed
// it at, so an instance the user runs themselves cannot be restarted by the app.

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';
import 'support/ready_mux.dart';

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final _readyMux = ReadyMux();

  @override
  DshMux get mux => _readyMux;
}

void main() {
  test('attach-only never probes or starts DSH and has no managed restart', () async {
    final server = FakeSshServer();
    server.remote.pid = 42;
    server.remote.port = 40100;
    server.remote.token = 'existing';
    final link = SshHostLink(
      config: sampleSsh.copyWith(dshMode: SshDshMode.attachOnly, remotePort: 40100),
      loadSecrets: () async => const SshSecrets(password: 'pw', attachToken: 'existing'),
      transportFactory: server.connect,
      connectClient: ({required baseUri, required token, required hostHeader}) async => _Client(),
      backoff: Backoff(initial: const Duration(milliseconds: 5), maxAttempts: 2),
    );
    addTearDown(link.close);

    await link.open();
    expect(server.transports.single.scripts, isEmpty, reason: 'attach must run no remote command');
    expect(link.endpoint!.reused, isTrue);
    expect(server.transports.single.tunnels.first, ('127.0.0.1', 40100));

    await expectLater(link.stopManaged(), throwsA(isA<StateError>()));
    await expectLater(link.restartManaged(), throwsA(isA<StateError>()));
    expect(server.transports.single.scripts, isEmpty, reason: 'a rejected stop/restart must not start a process');
  });
}
