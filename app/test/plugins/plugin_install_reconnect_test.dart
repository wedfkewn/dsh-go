// An install that is already running on the Host must not disappear from the
// screen when the link blips: the request keeps running on that server, so its
// card, progress and final result come back with the link. Only a *different*
// Host starts empty. This is the state-layer half of "多主机重连".

import 'dart:async';

import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_plugin_host.dart';

class _Host extends Notifier<PluginHost?> {
  _Host(this.initial);
  final PluginHost? initial;
  @override
  PluginHost? build() => initial;
  void set(PluginHost? host) => state = host;
}

final _hostProvider = NotifierProvider<_Host, PluginHost?>(() => _Host(null));

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;
  late ProviderContainer container;
  late Completer<Object?> installGate;
  final entry = officialFixtureMarket().byName['@dsh-go/media']!;

  setUp(() async {
    installGate = Completer<Object?>();
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
    carrier.handlers['pluginManager/installBundle'] = (_) => installGate.future;
    carrier.handlers['pluginManager/removeBundle'] = (_) => installResult(target: entry.name);
    container = ProviderContainer(
      overrides: [
        ...pluginOverrides(
          fakeHost(client),
          npmIntegrity: (_, _) async => entry.listing!.integrity,
        ),
        _hostProvider.overrideWith(() => _Host(PluginHost.of(fakeHost(client)))),
        pluginHostProvider.overrideWith((ref) => ref.watch(_hostProvider)),
      ],
    );
    container.listen(pluginInstallsProvider, (_, _) {});
    await container.read(installedPluginsProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await client.close();
  });

  test('a reconnect keeps the running install card and its result', () async {
    final result = container.read(pluginInstallsProvider.notifier).install(marketInstallRequest(entry));
    await pumpEventQueue();
    expect(carrier.argsOf('pluginManager/installBundle'), hasLength(1));
    expect(container.read(pluginInstallsProvider)[entry.name]?.isActive, isTrue);

    // The mux reconnects: the plugin host is null while the link is down.
    container.read(_hostProvider.notifier).set(null);
    await pumpEventQueue();
    expect(
      container.read(pluginInstallsProvider)[entry.name],
      isNotNull,
      reason: 'the request still runs on the Host; the card must not vanish',
    );

    container.read(_hostProvider.notifier).set(PluginHost.of(fakeHost(client)));
    installGate.complete(installResult(target: entry.name));
    expect((await result).phase, PluginInstallPhase.succeeded);
    expect(container.read(pluginInstallsProvider)[entry.name]?.phase, PluginInstallPhase.succeeded);
  });

  test('another Host starts with no jobs of its own', () async {
    final result = container.read(pluginInstallsProvider.notifier).install(marketInstallRequest(entry));
    await pumpEventQueue();
    expect(container.read(pluginInstallsProvider)[entry.name], isNotNull);

    final otherClient = DshClient.withCarrier(FakePluginCarrier());
    addTearDown(otherClient.close);
    container.read(_hostProvider.notifier).set(PluginHost.of(fakeHost(otherClient)));
    await pumpEventQueue();

    expect(container.read(pluginInstallsProvider), isEmpty, reason: 'jobs belong to the Host they run on');

    installGate.complete(installResult(target: entry.name));
    await result;
  });
}
