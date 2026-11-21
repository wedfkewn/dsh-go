// 主机信息 on a tablet and at the largest Dynamic Type sizes: the page is one
// column of rows, so nothing may overflow sideways or clip a value when the
// text grows and the window widens. Overflow throws in tests, so a clean pump
// is the assertion.

import 'package:dsh_app/remote/ssh/ssh_session_service.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/ssh_session_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/host_info_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/support.dart' show FixedActiveHost;
import 'support/fake_ssh.dart' show sampleSsh;
import '../support/test_fonts.dart' show withTestFonts;

const _host = HostRef.ssh('lab');

/// No link: the page falls back to the config's ownership and says the file and
/// terminal features are known only once connected.
/// A host with a real-length fingerprint: the short fake value hid an overflow
/// of the value column that a `SHA256:` fingerprint produces.
class _FingerprintedHosts extends HostsController {
  @override
  HostsState build() => const HostsState(
    loaded: true,
    ssh: [
      SshHostConfig(
        id: 'lab',
        name: '实验室服务器',
        host: 'lab.example.com',
        port: 22,
        user: 'root',
        auth: SshAuthMethod.privateKey,
        hostKeyType: 'ssh-ed25519',
        hostKeyFingerprint: 'SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG',
      ),
    ],
  );
}

Widget _app({required Brightness brightness, required double textScale, required Size size}) {
  return ProviderScope(
    overrides: [
      hostsProvider.overrideWith(_FingerprintedHosts.new),
      activeHostProvider.overrideWith(() => FixedActiveHost(_host)),
      hostLinkProvider.overrideWith((ref, host) => null),
      // The facts probe has no server to talk to here; the page must show its
      // retry row rather than spin forever.
      sshSessionServiceProvider.overrideWith(
        (ref, host) => SshSessionService(
          config: sampleSsh,
          loadSecrets: () async => const SshSecrets(),
          transportFactory: (params, verify) async => throw const SocketException('offline'),
        ),
      ),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: withTestFonts(buildLightTheme()),
      darkTheme: withTestFonts(buildDarkTheme()),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: const HostInfoPage(host: _host),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (name, brightness, size, scale) in [
    ('iPhone light', Brightness.light, const Size(390, 844), 1.0),
    ('iPhone dark', Brightness.dark, const Size(390, 844), 1.0),
    ('iPhone largest text', Brightness.light, const Size(390, 844), 2.0),
    ('iPad portrait light', Brightness.light, const Size(834, 1194), 1.0),
    ('iPad portrait dark', Brightness.dark, const Size(834, 1194), 1.0),
    ('iPad largest text', Brightness.light, const Size(834, 1194), 2.0),
    ('iPad landscape largest text', Brightness.light, const Size(1194, 834), 2.0),
  ]) {
    testWidgets('主机信息 lays out on $name', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = size * 2;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(brightness: brightness, textScale: scale, size: size));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: '$name 不应溢出或抛异常');
      // Sections stay readable and everything important is on screen.
      expect(find.text('主机信息'), findsWidgets);
      expect(find.text('连接'), findsOneWidget);
      expect(find.text('远程系统'), findsOneWidget);
      expect(find.text('文件管理限制'), findsOneWidget);
      // Values are the config's, not placeholder dashes.
      expect(find.text('root@lab.example.com'), findsOneWidget);
      expect(find.text('私钥'), findsOneWidget);
      // The limits list is still complete at the largest sizes.
      expect(find.text('复制不递归：整个目录不会被复制'), findsOneWidget);
      expect(find.text('符号链接只标注，不跟随进入'), findsOneWidget);
    });
  }
}
