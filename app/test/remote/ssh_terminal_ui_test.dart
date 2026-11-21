// SSH terminal page over the shared state layer (`sshTerminalsProvider`): tabs
// are independent shells, the page asks for a 100x30 window, and a dropped
// connection ends the tab without reopening a shell. A new shell only starts
// when the person taps 新建终端 — the explicit reconnect the design requires.

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_app/remote/ssh/remote_shell.dart';
import 'package:dsh_app/remote/ssh/ssh_session_capabilities.dart';
import 'package:dsh_app/remote/ssh/ssh_session_service.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/ssh_session_state.dart';
import 'package:dsh_app/state/ssh_terminal_state.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/remote/ssh_terminal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../shell/golden_harness.dart';
import 'support/fake_ssh.dart';

const _host = HostRef.ssh('lab');

class _Pty implements SshPtySession {
  _Pty(this.options);

  final SshPtyOptions options;
  final _out = StreamController<Uint8List>.broadcast(sync: true);
  final _exit = Completer<int?>();
  var closed = false;

  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  void write(List<int> data) {}
  @override
  void resize({required int columns, required int rows}) {}
  @override
  Future<int?> get exitCode => _exit.future;
  @override
  Future<void> get done => _out.stream.drain<void>();
  @override
  void close() {
    if (closed) return;
    closed = true;
    if (!_exit.isCompleted) _exit.complete(null);
    unawaited(_out.close());
  }
}

class _Transport implements SshTransport, SshSessionHost {
  final _done = Completer<void>();
  final List<_Pty> ptys = [];
  var connects = 0;
  var closed = false;

  @override
  bool get supportsSftp => !closed;
  @override
  bool get supportsPty => !closed;
  @override
  Future<SshPtySession> openPty([SshPtyOptions options = const SshPtyOptions()]) async {
    final pty = _Pty(options);
    ptys.add(pty);
    return pty;
  }

  @override
  Future<SshFileSession> openSftp() => throw UnimplementedError();
  @override
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)}) async =>
      const RemoteExecResult(0, '', '');
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
    if (closed) return;
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }
}

/// One transport per connect, so an explicit new shell after a loss can open a
/// fresh connection and the test can tell the two apart.
class _Transports {
  final List<_Transport> all = [];

  Future<SshTransport> factory(SshConnectParams params, Object verify) async {
    final transport = _Transport();
    all.add(transport);
    return transport;
  }

  _Transport get last => all.last;
}

ProviderContainer? _pageContainer;

Future<ProviderContainer> _pumpPage(WidgetTester tester, _Transports transports) async {
  usePhoneSurface(tester);
  tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    goldenApp(
      home: const SshTerminalPage(host: _host),
      brightness: Brightness.light,
      overrides: [
        hostsProvider.overrideWith(FixedHosts.new),
        activeHostProvider.overrideWith(() => FixedActiveHost(_host)),
        sshSessionServiceProvider.overrideWith(
          (ref, host) => SshSessionService(
            config: sampleSsh,
            loadSecrets: () async => const SshSecrets(password: 'pw'),
            transportFactory: transports.factory,
          ),
        ),
      ],
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(tester.element(find.byType(SshTerminalPage)));
  _pageContainer = container;
  return container;
}

Future<void> _finish(WidgetTester tester) async {
  unawaited(_pageContainer?.read(sshSessionServiceProvider(_host))?.close() ?? Future.value());
  _pageContainer = null;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the first tab asks for a 100x30 shell and 新建终端 adds a second one', (tester) async {
    final transports = _Transports();
    await _pumpPage(tester, transports);

    expect(transports.last.ptys, hasLength(1));
    final first = transports.last.ptys.single;
    expect((first.options.columns, first.options.rows), (100, 30));
    expect(find.byType(InputChip), findsOneWidget);

    await tester.tap(find.byTooltip('新建终端'));
    await tester.pumpAndSettle();
    expect(transports.last.ptys, hasLength(2));
    expect(find.byType(InputChip), findsNWidgets(2));
    await _finish(tester);
  });

  testWidgets('closing one tab leaves the other shell running', (tester) async {
    final transports = _Transports();
    await _pumpPage(tester, transports);
    await tester.tap(find.byTooltip('新建终端'));
    await tester.pumpAndSettle();

    final ptys = transports.last.ptys;
    await tester.tap(find.descendant(of: find.byType(InputChip).first, matching: find.byIcon(AppIcons.close)));
    await tester.pumpAndSettle();
    expect(ptys.first.closed, isTrue);
    expect(ptys.last.closed, isFalse);
    expect(find.byType(InputChip), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('a dropped connection ends the tab and does not reopen a shell by itself', (tester) async {
    final transports = _Transports();
    final container = await _pumpPage(tester, transports);
    expect(transports.all, hasLength(1));

    transports.last.close();
    await tester.pumpAndSettle();

    final state = container.read(sshTerminalsProvider(_host));
    expect([for (final tab in state.tabs) tab.status], everyElement(SshTabStatus.ended));
    expect(state.tabs.single.failure?.kind, SshFailureKind.connectionLost);
    expect(find.textContaining('连接已断开'), findsOneWidget);
    expect(transports.all, hasLength(1), reason: '掉线后不得自动重连或重开 shell');
    expect(transports.last.ptys, hasLength(1));

    // The person explicitly retries: a new connection and shell are opened.
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(transports.all, hasLength(2), reason: '显式重试才建新连接');
    expect(transports.last.ptys, hasLength(1));
    expect(
      container.read(sshTerminalsProvider(_host)).tabs.where((t) => t.status == SshTabStatus.running),
      hasLength(1),
    );
    await _finish(tester);
  });

  testWidgets('a host the state layer cannot serve says so instead of an empty terminal', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: SshTerminalPage(host: HostRef.local),
        brightness: Brightness.light,
        overrides: [
          hostsProvider.overrideWith(FixedHosts.new),
          activeHostProvider.overrideWith(() => FixedActiveHost(HostRef.local)),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('不支持'), findsWidgets);
  });
}
