// Credential hygiene: SSH secrets live in the secret store only, never in
// SharedPreferences or the host config JSON; a managed-start failure never
// echoes the launch token in its error detail.

import 'dart:convert';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/remote_bootstrap.dart';
import 'package:dsh_app/remote/ssh/remote_shell.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemorySecretStore secrets;

  ProviderContainer container() {
    final c = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(secrets)]);
    addTearDown(c.dispose);
    return c;
  }

  SshHostConfig host(
    String id, {
    SshDshMode mode = SshDshMode.managed,
    SshAuthMethod auth = SshAuthMethod.password,
    int remotePort = 3080,
  }) => SshHostConfig(
    id: id,
    name: '电脑',
    host: '192.168.1.20',
    user: 'me',
    auth: auth,
    dshMode: mode,
    remotePort: remotePort,
    hostKeyType: 'ssh-ed25519',
    hostKeyFingerprint: 'SHA256:goodkeygoodkeygoodkeygoodkeygoodkey00000',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets = MemorySecretStore();
  });

  test('passwords, private keys and attach tokens stay out of preferences and config JSON', () async {
    const password = 'password-must-not-leak';
    const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\npem-body-must-not-leak\n-----END OPENSSH PRIVATE KEY-----';
    const passphrase = 'passphrase-must-not-leak';
    const token = 'attach-token-must-not-leak';
    final c = container();
    final hosts = c.read(hostsProvider.notifier);
    await hosts.ready;
    await hosts.saveSsh(
      host('ssh-password'),
      secrets: const SshSecrets(password: password),
    );
    await hosts.saveSsh(
      host('ssh-key', auth: SshAuthMethod.privateKey),
      secrets: const SshSecrets(privateKey: pem, passphrase: passphrase),
    );
    await hosts.saveSsh(
      host('ssh-attach', mode: SshDshMode.attachOnly, remotePort: 4080),
      secrets: const SshSecrets(attachToken: token),
    );

    final prefs = await SharedPreferences.getInstance();
    final stored = [for (final key in prefs.getKeys()) '$key=${prefs.get(key)}'].join('\n');
    for (final secret in [password, pem, 'pem-body-must-not-leak', passphrase, token]) {
      expect(stored, isNot(contains(secret)), reason: 'preferences must not hold $secret');
    }
    final configs = prefs.getString(HostsController.prefsKey)!;
    for (final key in ['password', 'privateKey', 'passphrase', 'attachToken']) {
      expect(configs, isNot(contains('"$key":')), reason: 'config JSON must not carry $key');
    }
    expect(jsonDecode(configs), hasLength(3));
    for (final saved in c.read(hostsProvider).ssh) {
      expect(saved.toJson().keys, isNot(contains('password')));
      expect(saved.toJson().keys, isNot(contains('privateKey')));
      expect(saved.toJson().keys, isNot(contains('attachToken')));
    }
  });

  test('secrets are namespaced per host and read back only for their own host', () async {
    final c = container();
    final hosts = c.read(hostsProvider.notifier);
    await hosts.ready;
    await hosts.saveSsh(host('ssh-one'), secrets: const SshSecrets(password: 'one-password'));
    await hosts.saveSsh(
      host('ssh-two', mode: SshDshMode.attachOnly, remotePort: 4090),
      secrets: const SshSecrets(attachToken: 'two-token'),
    );

    final one = await hosts.loadSecrets('ssh-one');
    final two = await hosts.loadSecrets('ssh-two');
    expect(one.password, 'one-password');
    expect(one.attachToken, isNull);
    expect(two.password, isNull);
    expect(two.attachToken, 'two-token');
    expect(secrets.values.keys.where((key) => key.contains('password')), ['ssh.ssh-one.password']);
    expect(secrets.values.keys.where((key) => key.contains('attachToken')), ['ssh.ssh-two.attachToken']);
  });

  test('a timed-out managed start does not echo the launch token', () {
    const token = 'launch-token-must-not-leak';
    HostLinkError? error;
    try {
      RemoteDshBootstrap.parseStart(
        const RemoteExecResult(
          1,
          'DSHAPP home /home/me\nDSHAPP timeout\n'
          'DSHAPP log dsh web: http://127.0.0.1:40100/?token=launch-token-must-not-leak\n',
          '',
        ),
      );
    } on HostLinkError catch (e) {
      error = e;
    }
    expect(error, isNotNull);
    expect(error!.kind, HostLinkErrorKind.dshTimeout);
    expect(error.detail, isNot(contains(token)));
    expect(error.detail, contains('token=•••'));
    expect(redactRemoteTokens('token=$token&x=1'), 'token=•••&x=1');
  });
}
