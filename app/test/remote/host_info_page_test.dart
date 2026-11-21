// 主机信息: the page reads one probe over the shared SSH session and shows the
// connection facts the app already holds. These checks pin the content, the
// failed-probe path with a working retry, and that the layout survives a phone,
// an iPad and 2x text in dark mode without overflowing.

import 'dart:async';

import 'package:dsh_app/remote/ssh/remote_shell.dart';
import 'package:dsh_app/remote/ssh/ssh_session_capabilities.dart';
import 'package:dsh_app/remote/ssh/ssh_session_service.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/ssh_session_state.dart';
import 'package:dsh_app/ui/remote/host_info_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/support.dart' show FixedActiveHost;
import '../shell/golden_harness.dart';
import 'support/fake_ssh.dart';

const _host = HostRef.ssh('lab');

class _Hosts extends HostsController {
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
        hostKeyFingerprint: 'SHA256:goodkeygoodkeygoodkeygoodkeygoodkey00000',
      ),
    ],
  );
}

const _facts = '''
os=Linux
kernel=6.8.0-45-generic
arch=x86_64
host=lab-box
cpus=8
mem_kb=16384000
load=0.12 0.20 0.31 1/234 5678
uptime=93784.5
disk=/dev/sda1 102400000 51200000 46000000 53% /
''';

class _Transport implements SshTransport, SshSessionHost {
  String facts = _facts;
  Object? runError;
  final _done = Completer<void>();
  bool closed = false;
  int runs = 0;

  @override
  bool get supportsSftp => !closed;
  @override
  bool get supportsPty => !closed;

  @override
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)}) async {
    runs++;
    if (runError case final error?) throw error;
    return RemoteExecResult(0, facts, '');
  }

  @override
  Future<SshFileSession> openSftp() => throw UnimplementedError();
  @override
  Future<SshPtySession> openPty([SshPtyOptions options = const SshPtyOptions()]) => throw UnimplementedError();
  @override
  Future<TunnelChannel> openTunnel(String host, int port) => throw UnimplementedError();
  @override
  Future<void> ping({Duration timeout = const Duration(seconds: 10)}) async {}
  @override
  Future<void> get done => _done.future;
  @override
  bool get isClosed => closed;
  @override
  void close() {
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }
}

SshSessionService _service(_Transport transport) => SshSessionService(
  config: sampleSsh,
  loadSecrets: () async => const SshSecrets(password: 'pw'),
  transportFactory: (params, verify) async => transport,
);

List<Override> _overrides(_Transport transport) => [
  hostsProvider.overrideWith(_Hosts.new),
  activeHostProvider.overrideWith(() => FixedActiveHost(_host)),
  sshSessionServiceProvider.overrideWith((ref, host) => _service(transport)),
];

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Transport transport, {
  Brightness brightness = Brightness.light,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(size.width * 2, size.height * 2);
  tester.view.padding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  tester.view.viewPadding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    goldenApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: const HostInfoPage(host: _host),
        ),
      ),
      brightness: brightness,
      overrides: _overrides(transport),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(HostInfoPage)));
}

/// Closes the shared SSH service (its timers) before the tree goes away.
Future<void> _finish(WidgetTester tester, ProviderContainer container) async {
  unawaited(container.read(sshSessionServiceProvider(_host))?.close() ?? Future<void>.value());
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('reads the host once and shows connection and system facts', (tester) async {
    final transport = _Transport();
    final container = await _pump(tester, transport);

    expect(transport.runs, 1, reason: '一次只读探测');
    expect(find.text('主机信息'), findsWidgets);
    // Connection facts come from the saved config, not the network.
    expect(find.text('root@lab.example.com'), findsOneWidget);
    expect(find.text('私钥'), findsOneWidget);
    expect(find.textContaining('ssh-ed25519'), findsOneWidget);
    // System facts come from the probe.
    expect(find.text('Linux'), findsOneWidget);
    expect(find.text('6.8.0-45-generic'), findsOneWidget);
    expect(find.text('lab-box'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('0.12 · 0.20 · 0.31'), findsOneWidget);
    expect(find.text('1 d 2 h'), findsOneWidget);
    expect(find.text('只读取，不改动服务器上的任何东西'), findsOneWidget);
    // The honest limits list stays on the page (it sits below the fold).
    await tester.scrollUntilVisible(find.textContaining('复制不递归'), 200);
    expect(find.textContaining('复制不递归'), findsOneWidget);
    expect(find.textContaining('不能批量下载到手机'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });

  testWidgets('a failed probe offers a retry that reads again', (tester) async {
    final transport = _Transport()..runError = const HostLinkError(HostLinkErrorKind.unreachable, 'boom');
    final container = await _pump(tester, transport);

    expect(find.text('读取主机信息失败'), findsOneWidget);
    expect(find.text('Linux'), findsNothing);

    transport
      ..runError = null
      ..facts = 'os=Darwin\nkernel=23.6.0\narch=arm64\nhost=mac\n';
    await tester.tap(find.text('读取主机信息失败'));
    await tester.pumpAndSettle();

    expect(transport.runs, 2, reason: '重试要重新探测');
    expect(find.text('Darwin'), findsOneWidget);
    expect(find.text('arm64'), findsOneWidget);
    expect(find.text('读取主机信息失败'), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });

  testWidgets('a phone in dark mode lays out without overflowing', (tester) async {
    final transport = _Transport();
    final container = await _pump(tester, transport, brightness: Brightness.dark);

    expect(find.text('Linux'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });

  testWidgets('an iPad with 2x text lays out without overflowing', (tester) async {
    final transport = _Transport();
    final container = await _pump(
      tester,
      transport,
      brightness: Brightness.dark,
      size: const Size(1024, 1366),
      textScale: 2,
    );

    expect(find.text('主机信息'), findsWidgets);
    expect(find.text('lab-box'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '大字号 + iPad 不能有 RenderFlex overflow');
    await _finish(tester, container);
  });
}
