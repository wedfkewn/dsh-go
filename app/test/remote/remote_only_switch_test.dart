// Remote Only builds carry no local engine, so the remote screen must not
// offer a way back to 本机. A Full build with the runtime present must. Run:
//
//   flutter test --dart-define=DSH_REMOTE_ONLY=true test/remote/remote_only_switch_test.dart
//   flutter test test/remote/remote_only_switch_test.dart

import 'package:dsh_app/build_variant.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../shell/golden_harness.dart';
import 'support/fake_relay.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RemoteScreen(),
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
          activeHostProvider.overrideWith(() => FixedActiveHost(const HostRef.ssh('lab'))),
          hostsProvider.overrideWith(FixedHosts.new),
          hostLinkStatusProvider.overrideWith(
            (ref, host) => Stream.value(const HostLinkStatus(HostLinkPhase.connected)),
          ),
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          relayBackendProvider.overrideWithValue(FakeRelayBackend()),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
    'Remote Only build does not offer 切回本机',
    (tester) async {
      await pump(tester);
      expect(find.text('切回本机'), findsNothing);
    },
    skip: !remoteOnlyBuild,
  );

  testWidgets(
    'Full build with a runtime offers 切回本机',
    (tester) async {
      await pump(tester);
      expect(find.text('切回本机'), findsOneWidget);
    },
    skip: remoteOnlyBuild,
  );
}
