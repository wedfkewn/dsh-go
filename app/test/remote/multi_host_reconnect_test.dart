// Two SSH hosts are two independent links: one dropping its keepalive may
// reconnect (or give up) on its own, and neither the other host's client, its
// transport count nor its status may change. Reconnecting is not a global
// event, and a failed reconnect must not take a working host with it.

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';
import 'support/wait.dart';

const _lab = HostRef.ssh('lab');
const _pc = HostRef.ssh('pc');

const _fingerprint = 'SHA256:goodkeygoodkeygoodkeygoodkeygoodkey00000';

HostsState _twoHosts() => const HostsState(
  loaded: true,
  ssh: [
    SshHostConfig(
      id: 'lab',
      name: '实验室服务器',
      host: '127.0.0.1',
      user: 'me',
      hostKeyType: 'ssh-ed25519',
      hostKeyFingerprint: _fingerprint,
    ),
    SshHostConfig(
      id: 'pc',
      name: '家里的电脑',
      host: '127.0.0.1',
      user: 'me',
      hostKeyType: 'ssh-ed25519',
      hostKeyFingerprint: _fingerprint,
    ),
  ],
);

class _TwoHosts extends HostsController {
  @override
  HostsState build() => _twoHosts();
}

/// Fast backoff so a reconnect test takes milliseconds.
Backoff _quick({int? maxAttempts = 5}) =>
    Backoff(initial: const Duration(milliseconds: 10), max: const Duration(milliseconds: 30), maxAttempts: maxAttempts);

void main() {
  late Map<String, FakeSshServer> servers;
  late FakeConnector connector;
  late List<SshHostLink> links;
  late ProviderContainer container;

  setUp(() {
    servers = {'lab': FakeSshServer(), 'pc': FakeSshServer()};
    connector = FakeConnector();
    links = [];
    container = ProviderContainer(
      overrides: [
        hostsProvider.overrideWith(_TwoHosts.new),
        sshLinkFactoryProvider.overrideWithValue((ref, config) {
          final link = SshHostLink(
            config: config,
            loadSecrets: () async => const SshSecrets(password: 'pw'),
            pinHostKey: (_) async {},
            transportFactory: servers[config.id]!.connect,
            connectClient: connector.call,
            backoff: _quick(),
            keepAliveInterval: const Duration(milliseconds: 20),
            keepAliveTimeout: const Duration(milliseconds: 20),
          );
          links.add(link);
          return link;
        }),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() async {
    for (final link in links) {
      await link.close();
    }
  });

  /// Keeps both auto-dispose links alive and returns them.
  ({HostLink lab, HostLink pc}) both() {
    final labSub = container.listen(hostLinkProvider(_lab), (_, _) {});
    final pcSub = container.listen(hostLinkProvider(_pc), (_, _) {});
    addTearDown(pcSub.close);
    addTearDown(labSub.close);
    final lab = container.read(hostLinkProvider(_lab))!;
    final pc = container.read(hostLinkProvider(_pc))!;
    expect(lab, isNot(same(pc)), reason: '每台主机一条独立链路');
    return (lab: lab, pc: pc);
  }

  test('one host reconnecting leaves the other host untouched', () async {
    final (:lab, :pc) = both();
    final labClient = await lab.open();
    final pcClient = await pc.open();
    expect(servers['lab']!.transports, hasLength(1));
    expect(servers['pc']!.transports, hasLength(1));

    // Record what the other host reports while the lab host reconnects.
    final pcPhases = <HostLinkPhase>[];
    final pcSub = pc.statuses.listen((status) => pcPhases.add(status.phase));
    addTearDown(pcSub.cancel);

    // Only the lab host stops answering keepalives.
    servers['lab']!.last.pingOk = false;

    await nextStatus(lab, (s) => s.phase == HostLinkPhase.reconnecting, what: 'lab 进入重连');
    await nextStatus(lab, (s) => s.phase == HostLinkPhase.connected, what: 'lab 重连成功');

    expect(lab.currentClient, same(labClient), reason: '重连复用同一个 DSH 进程的客户端，只重连 mux');
    expect(servers['lab']!.remote.launches, 1, reason: '网络抖动不重启 DSH 实例');
    expect(servers['lab']!.transports, hasLength(2), reason: '重连只新建自己的一条传输');
    expect(servers['pc']!.transports, hasLength(1), reason: '另一台主机不得重连');
    expect(pc.currentClient, same(pcClient), reason: '另一台主机的客户端不变');
    expect(pc.status.phase, HostLinkPhase.connected);
    expect(servers['pc']!.last.isClosed, isFalse, reason: '另一台主机的传输没有被拆掉');
    expect(pcPhases, isNot(contains(HostLinkPhase.reconnecting)), reason: '另一台主机不进入重连');
    expect(pcPhases, isNot(contains(HostLinkPhase.failed)));
  });

  test('a host whose reconnect gives up fails alone', () async {
    final (:lab, :pc) = both();
    await lab.open();
    final pcClient = await pc.open();

    final pcPhases = <HostLinkPhase>[];
    final pcSub = pc.statuses.listen((status) => pcPhases.add(status.phase));
    addTearDown(pcSub.cancel);

    // Every reconnect attempt for the lab host is refused; the pc host keeps
    // answering normally.
    servers['lab']!.last.pingOk = false;
    for (var i = 0; i < 8; i++) {
      servers['lab']!.failNext.add(const HostLinkError(HostLinkErrorKind.unreachable, 'refused', retryable: true));
    }

    await nextStatus(lab, (s) => s.phase == HostLinkPhase.failed, what: 'lab 重连放弃');

    final error = lab.status.error!;
    expect(error.retryable, isTrue, reason: '网络类失败可以重试');
    expect(error.message, 'refused');
    expect(servers['lab']!.transports, hasLength(1), reason: '连接失败的尝试不留下传输');
    expect(pc.status.phase, HostLinkPhase.connected, reason: '一台失败不影响另一台');
    expect(pc.currentClient, same(pcClient));
    expect(servers['pc']!.transports, hasLength(1));
    expect(pcPhases, isNot(contains(HostLinkPhase.failed)), reason: '另一台主机不跟着失败');
  });
}
