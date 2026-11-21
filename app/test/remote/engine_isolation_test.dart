// Engine isolation: the phone's API key belongs to the on-device engine only,
// and a remote host connecting, failing or being switched to never stops or
// replaces the local engine. The SSH path pushes no phone credentials to the
// remote host.

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_ssh.dart';
import 'support/ready_mux.dart';
import 'support/wait.dart';

class _Runtime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() => LocalRuntimeState(
    loaded: true,
    status: RuntimeStatus.fromMap({
      'phase': 'running',
      'baseUrl': 'http://127.0.0.1:9',
      'token': 'local-token',
    }),
  );
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true, apiKey: 'sk-phone-only');
}

class _RecordingClient extends DshClient {
  _RecordingClient() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final List<String> pushedKeys = [];
  final _readyMux = ReadyMux();
  bool closed = false;

  @override
  DshMux get mux => _readyMux;

  @override
  Future<void> setProviderKey(String apiKey, {String ref = 'DEEPSEEK_API_KEY'}) async => pushedKeys.add(apiKey);

  @override
  Future<void> clearProviderKey({String ref = 'DEEPSEEK_API_KEY'}) async {}

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemorySecretStore secrets;
  late FakeSshServer server;
  late _RecordingClient localClient;
  late _RecordingClient remoteClient;

  ProviderContainer container() {
    final c = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localRuntimeProvider.overrideWith(_Runtime.new),
        networkKicksProvider.overrideWithValue(const Stream.empty()),
        secretStoreProvider.overrideWithValue(secrets),
        localClientConnectorProvider.overrideWithValue(
          ({required baseUri, required token}) async => localClient,
        ),
        sshLinkFactoryProvider.overrideWithValue(
          (ref, config) => SshHostLink(
            config: config,
            loadSecrets: () => ref.read(hostsProvider.notifier).loadSecrets(config.id),
            transportFactory: server.connect,
            connectClient: ({required baseUri, required token, required hostHeader}) async => remoteClient,
            backoff: Backoff(initial: const Duration(milliseconds: 5), maxAttempts: 2),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets = MemorySecretStore();
    server = FakeSshServer();
    localClient = _RecordingClient();
    remoteClient = _RecordingClient();
  });

  test('the phone API key goes to the local engine only, and an SSH host never stops it', () async {
    final c = container();
    final sub = c.listen(activeConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    await until(c, activeConnectionProvider, (s) => s.value != null, what: '本机连接');
    expect(localClient.pushedKeys, ['sk-phone-only']);

    final hosts = c.read(hostsProvider.notifier);
    await hosts.ready;
    await hosts.saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
    c.read(activeHostProvider.notifier).select(HostRef.ssh(sampleSsh.id));
    final remote = await until(
      c,
      activeConnectionProvider,
      (s) => s.value != null && !s.value!.isLocal,
      what: '远程连接',
    );
    expect(remote.value!.kind, HostKind.ssh);
    expect(remoteClient.pushedKeys, isEmpty);
    expect(c.read(localRuntimeProvider).status.phase, RuntimePhase.running);
    expect(localClient.closed, isFalse);

    // Switching back keeps the same local client; the remote never got the key.
    c.read(activeHostProvider.notifier).select(HostRef.local);
    await until(c, activeConnectionProvider, (s) => s.value?.isLocal ?? false, what: '回到本机');
    expect(c.read(activeConnectionProvider).value!.client, same(localClient));
    expect(remoteClient.pushedKeys, isEmpty);
    expect(localClient.closed, isFalse);
  });

  test('a failing SSH host leaves the local engine running', () async {
    server.failNext.addAll([
      const HostLinkError(HostLinkErrorKind.unreachable, 'offline'),
      const HostLinkError(HostLinkErrorKind.unreachable, 'offline'),
    ]);
    final c = container();
    final sub = c.listen(activeConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    await until(c, activeConnectionProvider, (s) => s.value != null, what: '本机连接');

    final hosts = c.read(hostsProvider.notifier);
    await hosts.ready;
    await hosts.saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
    c.read(activeHostProvider.notifier).select(HostRef.ssh(sampleSsh.id));
    final failed = await until(c, activeConnectionProvider, (s) => s.hasError, what: '远程失败');
    expect(failed.error, isA<HostLinkError>());
    expect(c.read(localRuntimeProvider).status.phase, RuntimePhase.running);
    expect(localClient.closed, isFalse);
    expect(localClient.pushedKeys, ['sk-phone-only']);
  });
}
