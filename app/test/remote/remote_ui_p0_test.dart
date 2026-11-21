// P0 UI acceptance for the remote workbench and SSH host sheet: the five
// header facts, the eight entries with disabled reasons, the three ownership
// labels, attach-target persistence, the attach-mode absolute-path rule, and
// the stop confirmation that must come before stopManaged().

import 'dart:convert';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/host_info_page.dart';
import 'package:dsh_app/ui/remote/ssh_host_form.dart';
import 'package:dsh_app/ui/remote/ssh_ownership.dart';
import 'package:dsh_app/ui/remote/workbench/remote_workbench_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../shell/golden_harness.dart';
import 'support/fake_ssh.dart';

class _FakeLink extends SshHostLink {
  _FakeLink(this._ownership) : super(config: sampleSsh, loadSecrets: () async => const SshSecrets());

  final SshDshOwnership? _ownership;
  int stops = 0;

  @override
  SshDshOwnership? get ownership => _ownership;

  @override
  HostLinkStatus get status => const HostLinkStatus(HostLinkPhase.connected);

  @override
  Future<void> stopManaged() async {
    stops++;
  }
}

void main() {
  Future<void> pumpWorkbench(WidgetTester tester, _FakeLink link) async {
    usePhoneSurface(tester);
    tester.view.physicalSize = const Size(390 * 2, 1500 * 2);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      goldenApp(
        home: const RemoteWorkbenchPage(host: HostRef.ssh('lab')),
        brightness: Brightness.light,
        overrides: [
          hostsProvider.overrideWith(FixedHosts.new),
          activeHostProvider.overrideWith(() => FixedActiveHost(const HostRef.ssh('lab'))),
          hostLinkProvider.overrideWith((ref, host) => link),
          hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(const HostLinkStatus(HostLinkPhase.connected))),
          activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('workbench shows the five header facts and all eight entries', (tester) async {
    final link = _FakeLink(SshDshOwnership.attached);
    await pumpWorkbench(tester, link);

    expect(find.text('实验室服务器'), findsOneWidget);
    expect(find.textContaining('SSH 已连接'), findsOneWidget);
    expect(find.textContaining('DSH 已就绪'), findsOneWidget);
    expect(find.textContaining('只连接 · 你的实例'), findsOneWidget);
    expect(find.text('当前工作区'), findsOneWidget);
    expect(find.text('全部对话'), findsOneWidget);
    expect(find.text('当前模型'), findsOneWidget);
    expect(find.text('没有连上引擎'), findsOneWidget);

    for (final title in ['AI 对话', '工作区', '服务器文件', 'SSH 终端', '模型管理', '插件', '主机信息', '连接设置']) {
      expect(find.text(title), findsWidgets, reason: title);
    }
    // These pages exist now; a fake transport without SshSessionHost says so.
    expect(find.text('这台主机不支持 SFTP'), findsOneWidget);
    expect(find.text('这台主机不支持 SSH 终端'), findsOneWidget);
    expect(find.text('系统、资源与实例所有权'), findsOneWidget, reason: '主机信息页已可用');

    // 主机信息 opens the real page; its read-only probe may fail on a transport
    // without exec, which the page reports instead of hiding the entry.
    await tester.tap(find.text('主机信息'));
    await tester.pumpAndSettle();
    expect(find.byType(HostInfoPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(HostInfoPage))).pop();
    await tester.pumpAndSettle();

    // A disabled entry does not navigate.
    await tester.tap(find.text('服务器文件'));
    await tester.pump();
    expect(find.byType(RemoteWorkbenchPage), findsOneWidget);
  });

  testWidgets('ownership labels cover all three states and the config fallback', (tester) async {
    usePhoneSurface(tester);
    final cases = <(SshDshOwnership?, SshHostConfig, String)>[
      (SshDshOwnership.attached, sampleSsh, '只连接 · 你的实例'),
      (SshDshOwnership.managedStarted, sampleSsh, '托管 · 本次启动'),
      (SshDshOwnership.managedReused, sampleSsh, '托管 · 复用已有'),
      (null, sampleSsh.copyWith(dshMode: SshDshMode.attachOnly), '只连接 · 你的实例'),
      (null, sampleSsh, '托管 · App 启动'),
    ];
    for (final (ownership, config, label) in cases) {
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: Builder(
            builder: (context) => Text(sshOwnershipLabel(context, config, ownership: ownership)!),
          ),
        ),
      );
      await tester.pump();
      expect(find.text(label), findsOneWidget);
    }
  });

  Future<ProviderContainer> pumpForm(
    WidgetTester tester,
    SshHostConfig config, {
    List<Override> overrides = const [],
  }) async {
    usePhoneSurface(tester);
    SharedPreferences.setMockInitialValues({HostsController.prefsKey: jsonEncode([config.toJson()])});
    final secrets = MemorySecretStore({
      SshSecrets.passwordKey(config.id): 'synthetic-password',
      SshSecrets.attachTokenKey(config.id): 'synthetic-token',
    });
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: [
          secretStoreProvider.overrideWithValue(secrets),
          sshTransportFactoryProvider.overrideWithValue(FakeSshServer().connect),
          ...overrides,
        ],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => SshHostFormPage(existing: config)),
              ),
              child: const Text('Open host'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open host'));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(SshHostFormPage)));
  }

  testWidgets('editing a saved attach host keeps its target address', (tester) async {
    final config = sampleSsh.copyWith(
      dshMode: SshDshMode.attachOnly,
      remotePort: 4080,
      attachHost: '10.0.0.5',
      workingDirectory: () => '/srv/app',
    );
    final container = await pumpForm(tester, config);

    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存'));
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    final saved = container.read(hostsProvider).sshById(config.id)!;
    expect(saved.attachHost, '10.0.0.5');
    expect(saved.remotePort, 4080);
    expect(saved.workingDirectory, '/srv/app');
  });

  testWidgets('attach mode rejects a relative working directory', (tester) async {
    final config = sampleSsh.copyWith(
      dshMode: SshDshMode.attachOnly,
      remotePort: 4080,
      workingDirectory: () => '/srv/app',
    );
    await pumpForm(tester, config);

    final cwd = find.byWidgetPredicate((widget) => widget is TextField && widget.controller?.text == '/srv/app');
    await tester.enterText(cwd, '~/work');
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存'));
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('只连接模式请填写绝对路径（以 / 开头）'), findsOneWidget);
    expect(find.byType(SshHostFormPage), findsOneWidget);
  });

  testWidgets('stopping the managed instance needs the confirmation first', (tester) async {
    final link = _FakeLink(SshDshOwnership.managedStarted);
    await pumpForm(
      tester,
      sampleSsh,
      overrides: [
        hostLinkProvider.overrideWith((ref, host) => link),
        hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(const HostLinkStatus(HostLinkPhase.connected))),
      ],
    );

    final stopButton = find.widgetWithText(TextButton, '停止托管 DSH');
    await tester.ensureVisible(stopButton);
    // The long form scrolls; invoke the enabled action directly so the test
    // checks the confirmation flow rather than a hit-test offset.
    final action = tester.widget<TextButton>(stopButton);
    expect(action.onPressed, isNotNull);
    action.onPressed!();
    await tester.pumpAndSettle();
    expect(find.text('停止这个托管实例？'), findsOneWidget);
    expect(link.stops, 0);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(link.stops, 0);

    await tester.ensureVisible(stopButton);
    tester.widget<TextButton>(stopButton).onPressed!();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '停止托管 DSH'));
    await tester.pumpAndSettle();
    expect(link.stops, 1);
  });
}
