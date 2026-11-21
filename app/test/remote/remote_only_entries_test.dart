// Remote Only builds carry no local engine, so the 引擎 entry must not open an
// empty page from any route: the drawer's identity bar goes through
// `_openDestination`, which answers with a notice; the settings hub drops the
// row altogether. A Full build keeps both. Run:
//
//   flutter test --dart-define=DSH_REMOTE_ONLY=true test/remote/remote_only_entries_test.dart
//   flutter test test/remote/remote_only_entries_test.dart

import 'package:dsh_app/build_variant.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../shell/golden_harness.dart';

const _noEngine = '这个版本不含本机引擎，请连接远程主机';

/// The settings hub is longer than a phone: lay it out tall so every group is
/// built, the way the hub's own geometry tests do.
void _tallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 2600 * 2);
  addTearDown(tester.view.reset);
}

Future<void> _pumpShell(WidgetTester tester) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
      overrides: [
        activeHostProvider.overrideWith(() => FixedActiveHost(HostRef.local)),
        hostsProvider.overrideWith(FixedHosts.new),
        localRuntimeProvider.overrideWith(
          () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
        ),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
      ],
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Remote Only: the drawer engine entry explains the build instead of opening a page',
    (tester) async {
      await _pumpShell(tester);

      await tester.tap(find.byTooltip('本机引擎'));
      await tester.pumpAndSettle();

      expect(find.text(_noEngine), findsOneWidget, reason: '要告诉用户这个版本没有本机引擎');
      expect(find.byType(EngineScreen), findsNothing, reason: '不得打开空的引擎页');
    },
    skip: !remoteOnlyBuild,
  );

  testWidgets(
    'Remote Only: the settings hub has no engine row',
    (tester) async {
      _tallSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const SettingsScreen(),
          brightness: Brightness.light,
          overrides: [
            activeHostProvider.overrideWith(() => FixedActiveHost(HostRef.local)),
            hostsProvider.overrideWith(FixedHosts.new),
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
            ),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('本机引擎'), findsNothing, reason: '没有引擎就不该提供安装/查看入口');
      expect(find.byType(EngineScreen), findsNothing);
    },
    skip: !remoteOnlyBuild,
  );

  testWidgets(
    'Full: the drawer engine entry still opens the engine page',
    (tester) async {
      await _pumpShell(tester);

      await tester.tap(find.byTooltip('本机引擎'));
      await tester.pumpAndSettle();

      expect(find.byType(EngineScreen), findsOneWidget, reason: '完整版必须保留原有入口');
      expect(find.text(_noEngine), findsNothing);
    },
    skip: remoteOnlyBuild,
  );

  testWidgets(
    'Full: the settings hub keeps the engine row',
    (tester) async {
      _tallSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const SettingsScreen(),
          brightness: Brightness.light,
          overrides: [
            activeHostProvider.overrideWith(() => FixedActiveHost(HostRef.local)),
            hostsProvider.overrideWith(FixedHosts.new),
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
            ),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('本机引擎'), findsOneWidget);
    },
    skip: remoteOnlyBuild,
  );
}
