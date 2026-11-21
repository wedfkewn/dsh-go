// The engine settings page and the plugin inventory must never read or write
// through activeConnectionProvider's local fallback. That provider answers for
// 本机 while a saved SSH host is selected but missing from the loaded host
// list, and a settings write through it would land on this device while the
// page says the server. The guarded provider (activeWriteConnectionProvider)
// filters by kind and host id, so the same window reads as offline.

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_plugin_host.dart';

class _SshSelection extends ActiveHostController {
  @override
  HostRef build() => HostRef.ssh('lab');
}

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;
  late ProviderContainer container;

  setUp(() {
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    container = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(_SshSelection.new),
        // What activeConnectionProvider exposes while the selected SSH host is
        // not in the loaded list: the local engine's connection.
        activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeHost(client))),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await client.close();
  });

  test('an unknown SSH host reads as offline, not as 本机', () async {
    expect(container.read(activeConnectionProvider).value?.isLocal, isTrue, reason: 'premise: the fallback exists');
    expect(container.read(activeWriteConnectionProvider), isNull, reason: 'the selected host is not this device');

    expect(await container.read(engineSettingsProvider.future), isNull);
    expect(await container.read(pluginInventoryProvider.future), isNull);
    expect(carrier.calls, isEmpty, reason: 'no settings or inventory request may reach the local engine');
  });
}
