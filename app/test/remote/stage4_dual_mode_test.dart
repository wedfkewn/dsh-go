import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/key_generation.dart';
import 'package:dsh_app/remote/transfer_consent.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generated OpenSSH key round trips and signs', () async {
    final key = await generateSshKey();
    final restored = SSHKeyPair.fromPem(key.toPem()).single;
    expect(restored.toPublicKey().encode(), key.toPublicKey().encode());
    final pair = restored as OpenSSHEd25519KeyPair;
    final public = pair.publicKey;
    final message = Uint8List.fromList([1, 2, 3]);
    expect(await Ed25519().verify(message, signature: Signature(
      pair.sign(message).signature,
      publicKey: SimplePublicKey(public, type: KeyPairType.ed25519),
    )), isTrue);
    expect(sshAuthorizedKey(key), startsWith('ssh-ed25519 '));
  });

  test('headless transfers are denied', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(await c.read(remoteTransferConsentProvider)(
      const RemoteTransfer(destination: 'test host', items: ['file.txt']),
    ), isFalse);
  });

  test('same session id and new draft stay separate across hosts and restart', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final drafts = c.read(draftStoreProvider.notifier);
    await drafts.flush();
    drafts.save('new', 'local draft', []);
    drafts.save('same', 'local session', []);
    c.read(activeHostProvider.notifier).select(const HostRef.ssh('test-host'));
    expect(c.read(draftStoreProvider).drafts, isEmpty);
    drafts.save('new', 'remote draft', []);
    drafts.save('same', 'remote session', []);
    c.read(activeHostProvider.notifier).select(HostRef.local);
    expect(c.read(draftStoreProvider).drafts['new']?.text, 'local draft');
    expect(c.read(draftStoreProvider).drafts['same']?.text, 'local session');
    await drafts.flush();
    final next = ProviderContainer();
    addTearDown(next.dispose);
    await next.read(activeHostProvider.notifier).ready;
    await next.read(draftStoreProvider.notifier).flush();
    expect(next.read(draftStoreProvider).drafts['same']?.text, 'local session');
  });

  test('missing remote host never selects a local client', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer(overrides: [
      secretStoreProvider.overrideWithValue(MemorySecretStore()),
    ]);
    addTearDown(c.dispose);
    await c.read(hostsProvider.notifier).ready;
    c.read(activeHostProvider.notifier).select(const HostRef.ssh('removed-host'));
    final connection = c.read(activeConnectionProvider);
    expect(connection.hasError, isTrue);
    expect(connection.error.toString(), contains('ssh_host_unavailable'));
  });

  test('legacy host list moves to secure storage', () async {
    SharedPreferences.setMockInitialValues({HostsController.prefsKey: '[]'});
    final secrets = MemorySecretStore();
    final c = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(secrets)]);
    addTearDown(c.dispose);
    await c.read(hostsProvider.notifier).ready;
    expect(await secrets.read(HostsController.prefsKey), '[]');
    expect((await SharedPreferences.getInstance()).containsKey(HostsController.prefsKey), isFalse);
  });
}
