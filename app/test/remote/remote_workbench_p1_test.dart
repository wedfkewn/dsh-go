// P1 workbench behavior: the 「AI 对话」 entry never lands on an empty local
// chat — with no conversation open it opens the remote session search, and the
// picked conversation becomes current. A failed link shows the one follow-up
// that can fix it: sign in again, edit the host (non-retryable), or retry.

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/session_search.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/ssh_session_state.dart';
import 'package:dsh_app/ui/remote/server_files_page.dart';
import 'package:dsh_app/ui/remote/ssh_terminal_page.dart';
import 'package:dsh_app/ui/remote/workbench/remote_workbench_page.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../search/support.dart';
import '../shell/golden_harness.dart';
import 'support/fake_ssh.dart';

class _FakeLink extends SshHostLink {
  _FakeLink({this.sftp = false, this.pty = false}) : super(config: sampleSsh, loadSecrets: () async => const SshSecrets());

  final bool sftp;
  final bool pty;

  @override
  HostLinkStatus get status => const HostLinkStatus(HostLinkPhase.connected);
  @override
  bool get hasSftp => sftp;
  @override
  bool get hasPty => pty;
}

const _lab = HostRef.ssh('lab');

List<Override> _baseOverrides(HostLinkStatus status) => [
  hostsProvider.overrideWith(FixedHosts.new),
  activeHostProvider.overrideWith(() => FixedActiveHost(_lab)),
  hostLinkProvider.overrideWith((ref, host) => _FakeLink(sftp: true, pty: true)),
  hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(status)),
  activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
  secretStoreProvider.overrideWithValue(MemorySecretStore()),
  sessionsProvider.overrideWith(() => SearchSessions(sampleSearchSessions())),
];

Future<ProviderContainer> pumpWorkbench(
  WidgetTester tester, {
  HostLinkStatus status = const HostLinkStatus(HostLinkPhase.connected),
  String? current,
}) async {
  usePhoneSurface(tester);
  tester.view.physicalSize = const Size(390 * 2, 1500 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    goldenApp(
      home: const RemoteWorkbenchPage(host: _lab),
      brightness: Brightness.light,
      overrides: [
        ..._baseOverrides(status),
        sshSessionServiceProvider.overrideWith((ref, host) => null),
        currentSessionProvider.overrideWith(() => FakeCurrentSession(current)),
        sessionContentSearchProvider.overrideWithValue(FakeContentSearch()),
      ],
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(RemoteWorkbenchPage)));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('AI 对话 with no open conversation opens the remote search and selects what was picked', (tester) async {
    final container = await pumpWorkbench(tester);
    expect(container.read(currentSessionProvider), isNull);

    await tester.tap(find.text('AI 对话'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionSearchPage), findsOneWidget, reason: '没有当前会话时先进入远程会话搜索');

    // The search page lists matches only once a query is typed.
    await tester.enterText(find.byType(TextField), '登录');
    await tester.pump();
    await tester.pump(SessionSearchController.debounce);
    await tester.pump();
    await tester.tap(find.text('修复登录按钮重复提交'));
    await tester.pumpAndSettle();

    expect(container.read(currentSessionProvider), 's1');
    expect(find.byType(SessionSearchPage), findsNothing);
    expect(find.byType(RemoteWorkbenchPage), findsOneWidget);
  });

  testWidgets('with a conversation already open, AI 对话 goes straight back without searching', (tester) async {
    final container = await pumpWorkbench(tester, current: 's3');
    await tester.tap(find.text('AI 对话'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionSearchPage), findsNothing);
    expect(container.read(currentSessionProvider), 's3');
  });

  testWidgets('a link that needs a sign-in offers 重新登录', (tester) async {
    await pumpWorkbench(
      tester,
      status: const HostLinkStatus(
        HostLinkPhase.failed,
        error: HostLinkError(HostLinkErrorKind.notLoggedIn, '请重新登录'),
      ),
    );
    expect(find.text('重新登录'), findsOneWidget);
  });

  testWidgets('a retryable link failure offers 重试', (tester) async {
    await pumpWorkbench(
      tester,
      status: const HostLinkStatus(
        HostLinkPhase.failed,
        error: HostLinkError(HostLinkErrorKind.unreachable, '连不上', retryable: true),
      ),
    );
    // The disconnected body offers 重试 as well; the error box's own action must exist.
    expect(find.text('重试'), findsWidgets);
  });

  testWidgets('a non-retryable failure offers 主机设置', (tester) async {
    await pumpWorkbench(
      tester,
      status: const HostLinkStatus(
        HostLinkPhase.failed,
        error: HostLinkError(HostLinkErrorKind.hostKeyMismatch, '指纹变了'),
      ),
    );
    expect(find.text('主机设置'), findsOneWidget);
  });

  testWidgets('with SSH up and no DSH, the file and terminal entries open their pages', (tester) async {
    // The connection is SSH only: `activeConnectionProvider` is null, so no DSH
    // client exists and no DSH RPC can succeed. The two pages must still open.
    await pumpWorkbench(tester);
    expect(find.text('服务器文件'), findsOneWidget);
    expect(find.text('SSH 终端'), findsOneWidget);

    await tester.tap(find.text('服务器文件'));
    await tester.pumpAndSettle();
    expect(find.byType(ServerFilesPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(ServerFilesPage))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('SSH 终端'));
    await tester.pumpAndSettle();
    expect(find.byType(SshTerminalPage), findsOneWidget);
  });

  testWidgets('the non-retryable link action opens the host settings', (tester) async {
    await pumpWorkbench(
      tester,
      status: const HostLinkStatus(
        HostLinkPhase.failed,
        error: HostLinkError(HostLinkErrorKind.hostKeyMismatch, '指纹变了'),
      ),
    );
    await tester.tap(find.text('主机设置'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteWorkbenchPage), findsNothing);
    expect(find.text('保存'), findsOneWidget, reason: '打开的是这个主机的编辑页');
  });
}
