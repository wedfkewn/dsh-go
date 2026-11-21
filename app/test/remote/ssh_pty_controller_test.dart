// PTY behavior over the DSH-independent session service, with an independent
// fake transport: the initial window the page asks for reaches the server,
// tabs have their own shells and window size, closing one leaves the other,
// output printed before a page subscribes is kept, and a dropped connection
// ends every tab without reconnecting or replaying what was typed.

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_app/remote/ssh/remote_shell.dart';
import 'package:dsh_app/remote/ssh/ssh_session_capabilities.dart';
import 'package:dsh_app/remote/ssh/ssh_session_service.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/ssh_session_state.dart';
import 'package:dsh_app/state/ssh_terminal_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';

const _host = HostRef.ssh('pc');

void keepTerminals(ProviderContainer container) {
  addTearDown(container.listen(sshTerminalsProvider(_host), (_, _) {}).close);
}

Future<void> settle([int turns = 12]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Pty implements SshPtySession {
  _Pty(this.options);

  final SshPtyOptions options;
  final _out = StreamController<Uint8List>.broadcast();
  final _exit = Completer<int?>();
  final List<String> written = [];
  final List<(int, int)> sizes = [];
  var closed = false;

  void emit(String text) => _out.add(Uint8List.fromList(text.codeUnits));

  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  void write(List<int> data) => written.add(String.fromCharCodes(data));
  @override
  void resize({required int columns, required int rows}) => sizes.add((columns, rows));
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
  bool get supportsSftp => false;
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

ProviderContainer _containerFor(_Transport transport) {
  final container = ProviderContainer(
    overrides: [
      sshSessionServiceProvider.overrideWith(
        (ref, host) => SshSessionService(
          config: sampleSsh,
          loadSecrets: () async => const SshSecrets(password: 'pw'),
          transportFactory: (params, verify) async {
            transport.connects++;
            return transport;
          },
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the window a page asks for reaches the pty and each tab keeps its own size', () async {
    final transport = _Transport();
    final container = _containerFor(transport);
    keepTerminals(container);
    final terminals = container.read(sshTerminalsProvider(_host).notifier);

    final first = await terminals.openTab(title: 'one', columns: 132, rows: 43);
    final second = await terminals.openTab(title: 'two');
    expect(transport.ptys, hasLength(2));
    expect((transport.ptys[0].options.columns, transport.ptys[0].options.rows), (132, 43));
    expect((transport.ptys[1].options.columns, transport.ptys[1].options.rows), (80, 24));

    terminals.resize(first, columns: 100, rows: 30);
    expect(transport.ptys[0].sizes, [(100, 30)]);
    expect(transport.ptys[1].sizes, isEmpty);

    terminals.resize(second, columns: 90, rows: 20);
    expect(transport.ptys[1].sizes, [(90, 20)]);
    expect(_terminalStatus(container, first), SshTabStatus.running);
    expect(_terminalStatus(container, second), SshTabStatus.running);
  });

  test('tabs are independent: bytes stay on their own tab and closing one leaves the other', () async {
    final transport = _Transport();
    final container = _containerFor(transport);
    keepTerminals(container);
    final terminals = container.read(sshTerminalsProvider(_host).notifier);

    final first = await terminals.openTab(title: 'one');
    final second = await terminals.openTab(title: 'two');
    final seenFirst = <int>[];
    final seenSecond = <int>[];
    final subA = terminals.outputOf(first).listen(seenFirst.addAll);
    final subB = terminals.outputOf(second).listen(seenSecond.addAll);
    addTearDown(subA.cancel);
    addTearDown(subB.cancel);

    transport.ptys[0].emit('from-one');
    transport.ptys[1].emit('from-two');
    await settle();
    expect(String.fromCharCodes(seenFirst), 'from-one');
    expect(String.fromCharCodes(seenSecond), 'from-two');

    terminals.write(first, 'ls\n');
    expect(transport.ptys[0].written, ['ls\n']);
    expect(transport.ptys[1].written, isEmpty);

    await terminals.closeTab(first);
    expect(transport.ptys[0].closed, isTrue);
    expect(transport.ptys[1].closed, isFalse);
    terminals.write(second, 'pwd\n');
    expect(transport.ptys[1].written, ['pwd\n']);
  });

  test('output printed before the page subscribes is delivered on listen', () async {
    final transport = _Transport();
    final container = _containerFor(transport);
    keepTerminals(container);
    final terminals = container.read(sshTerminalsProvider(_host).notifier);

    final id = await terminals.openTab();
    transport.ptys.single.emit('banner-before-subscribe');
    await settle();
    final seen = <int>[];
    final sub = terminals.outputOf(id).listen(seen.addAll);
    addTearDown(sub.cancel);
    await settle();
    expect(String.fromCharCodes(seen), 'banner-before-subscribe');
  });

  test('a lost connection ends every tab, does not reconnect and replays nothing', () async {
    final transport = _Transport();
    final container = _containerFor(transport);
    keepTerminals(container);
    final terminals = container.read(sshTerminalsProvider(_host).notifier);

    final first = await terminals.openTab();
    final second = await terminals.openTab();
    terminals.write(first, 'typed-before-loss\n');
    await settle();

    transport.close();
    await settle();

    final state = container.read(sshTerminalsProvider(_host));
    expect([for (final t in state.tabs) t.status], everyElement(SshTabStatus.ended));
    expect([for (final t in state.tabs) t.failure?.kind], everyElement(SshFailureKind.connectionLost));
    expect(transport.connects, 1, reason: '掉线不得自动重连');
    expect(transport.ptys[0].written, ['typed-before-loss\n'], reason: '已输入内容不得在掉线后重放');
    expect(transport.ptys[1].written, isEmpty);
    expect(first, isNot(second));
  });
}

SshTabStatus _terminalStatus(ProviderContainer container, String id) =>
    container.read(sshTerminalsProvider(_host)).tabs.firstWhere((t) => t.id == id).status;
