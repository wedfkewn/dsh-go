// Server files page over the shared SSH state layer (`sftpProvider`): the list,
// the dangerous-action confirmations, the transfer sheet with progress and
// cancel, and the fact that none of it needs DSH to be running — the fake
// service below only ever authenticates SSH and opens SFTP.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/remote/ssh/remote_shell.dart';
import 'package:dsh_app/remote/ssh/ssh_session_capabilities.dart';
import 'package:dsh_app/remote/ssh/ssh_session_service.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sftp_state.dart';
import 'package:dsh_app/state/ssh_session_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/remote/server_file_preview_page.dart';
import 'package:dsh_app/ui/remote/server_files_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../shell/golden_harness.dart';
import 'support/fake_path_provider.dart';
import 'support/fake_ssh.dart';

const _host = HostRef.ssh('lab');

class _Files implements SshFileSession {
  _Files({this.writeGateAt});

  /// Held after the first chunk of a download (progress stays mid-way).
  Completer<void>? readGate;

  /// Held from this many writes on (an upload paused by the person).
  final int? writeGateAt;
  Completer<void>? writeGate;

  final Map<String, Uint8List> bytes = {};
  final Map<String, List<SshFileEntry>> listings = {};
  final List<String> removes = [];
  final List<(String, int)> chmods = [];
  final List<(String, String)> renames = [];
  final List<String> madeDirs = [];
  final List<(String, int, int, bool, String)> writes = [];
  int readRangeCalls = 0;

  @override
  Future<List<SshFileEntry>> list(String path) async => listings[path] ?? const [];

  @override
  Future<SshFileStat> stat(String path, {bool followLinks = true}) async {
    final data = bytes[path];
    return SshFileStat(
      isDirectory: data == null && listings.containsKey(path),
      isSymbolicLink: false,
      isRegularFile: data != null,
      size: data?.length,
      mode: 0x1A4,
    );
  }

  @override
  Future<Uint8List> readRange(String path, {int offset = 0, int? length}) async {
    readRangeCalls++;
    if (offset > 0 && readGate != null) await readGate!.future;
    final data = bytes[path] ?? Uint8List(0);
    if (offset >= data.length) return Uint8List(0);
    final end = length == null ? data.length : (offset + length).clamp(0, data.length);
    return Uint8List.sublistView(data, offset, end);
  }

  @override
  Future<void> writeRange(
    String path,
    Uint8List data, {
    int offset = 0,
    bool create = true,
    bool truncate = false,
    bool append = false,
  }) async {
    final gateAt = writeGateAt;
    if (gateAt != null && writes.length >= gateAt) {
      writeGate ??= Completer<void>();
      await writeGate!.future;
    }
    writes.add((path, offset, data.length, truncate, utf8.decode(data, allowMalformed: true)));
  }

  @override
  Future<void> makeDirectory(String path) async => madeDirs.add(path);
  @override
  Future<void> remove(String path, {bool directory = false}) async => removes.add(path);
  @override
  Future<void> rename(String from, String to) async => renames.add((from, to));
  @override
  Future<void> chmod(String path, int mode) async => chmods.add((path, mode));
  @override
  Future<String> absolute(String path) async => path;
  @override
  Future<void> close() async {}
}

class _Transport implements SshTransport, SshSessionHost {
  _Transport(this.files);

  final _Files files;
  final _done = Completer<void>();
  var closed = false;
  var execCalls = 0;

  @override
  bool get supportsSftp => !closed;
  @override
  bool get supportsPty => false;
  @override
  Future<SshFileSession> openSftp() async => files;
  @override
  Future<SshPtySession> openPty([SshPtyOptions options = const SshPtyOptions()]) => throw UnimplementedError();
  @override
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)}) async {
    execCalls++;
    return const RemoteExecResult(0, '', '');
  }

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

SshSessionService _service(_Transport transport) => SshSessionService(
  config: sampleSsh,
  loadSecrets: () async => const SshSecrets(password: 'pw'),
  transportFactory: (params, verify) async => transport,
);

List<Override> _allOverrides(
  _Transport transport, {
  bool fixedHost = true,
  List<Override> extra = const [],
}) => [
  hostsProvider.overrideWith(FixedHosts.new),
  if (fixedHost) activeHostProvider.overrideWith(() => FixedActiveHost(_host)),
  sshSessionServiceProvider.overrideWith((ref, host) => _service(transport)),
  ...extra,
];

Future<ProviderContainer> _pumpPage(
  WidgetTester tester,
  _Transport transport, {
  bool fixedHost = true,
  List<Override> extra = const [],
}) async {
  usePhoneSurface(tester);
  tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    goldenApp(
      home: const ServerFilesPage(host: _host),
      brightness: Brightness.light,
      overrides: _allOverrides(transport, fixedHost: fixedHost, extra: extra),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(tester.element(find.byType(ServerFilesPage)));
  _pageContainer = container;
  if (!fixedHost) {
    container.read(activeHostProvider.notifier).select(_host);
    await tester.pumpAndSettle();
  }
  return container;
}

class _Workspaces extends WorkspacesController {
  final List<String> added = [];

  @override
  WorkspacesState build() => const WorkspacesState(status: WorkspacesStatus.ready);

  @override
  Future<Workspace> add(String path) async {
    added.add(path);
    return Workspace(workspaceId: 'ws-fake', path: path, title: 'fake', sessionIds: const []);
  }
}

_Workspaces? _workspacesFake;

_Files _sampleFiles() {
  final files = _Files();
  files.bytes['/notes.txt'] = Uint8List.fromList(utf8.encode('hello sftp'));
  files.listings['/'] = [
    const SshFileEntry(name: 'srv', isDirectory: true, isSymbolicLink: false, mode: 0x1ED),
    const SshFileEntry(name: 'notes.txt', isDirectory: false, isSymbolicLink: false, size: 10, mode: 0x1A4),
    const SshFileEntry(name: 'link.txt', isDirectory: false, isSymbolicLink: true, size: 10, mode: 0x1A4),
    const SshFileEntry(name: '.hidden', isDirectory: false, isSymbolicLink: false, size: 1, mode: 0x1A4),
  ];
  return files;
}

Finder _moreOf(String name) => find.descendant(
  of: find.ancestor(of: find.text(name), matching: find.byType(ListPageRow)),
  matching: find.byTooltip('更多'),
);

Finder _pageMenu() => find.byTooltip('更多').last;

Finder _transfersButton() => find.byWidgetPredicate(
  (widget) => widget is Tooltip && (widget.message ?? '').contains('传输'),
);


/// Advances real file IO (runAsync) and the fake zone (pump) together: the page
/// downloads into a real scratch file, and each disk step only completes once
/// the real event loop runs, then its continuation flushes on the next pump.
Future<void> _stepUntil(WidgetTester tester, bool Function() done, {int cycles = 400}) async {
  for (var i = 0; i < cycles; i++) {
    if (done()) {
      // One more pass: the continuation after the last disk step (a notice, a
      // navigation) is a microtask that the next pump has to flush.
      if (i > 0) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
        await tester.pump();
      }
      return;
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    await tester.pump();
  }
}

ProviderContainer? _pageContainer;

Future<void> _finish(WidgetTester tester) async {
  // Close the shared SSH service (its keepalive timer) before the test's timer
  // invariant runs; then unmount the page.
  unawaited(_pageContainer?.read(sshSessionServiceProvider(_host))?.close() ?? Future.value());
  _pageContainer = null;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('lists the SSH directory with no DSH running and filters hidden files', (tester) async {
    final transport = _Transport(_sampleFiles());
    await _pumpPage(tester, transport);

    expect(find.text('服务器文件'), findsWidgets);
    expect(find.text('srv'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('link.txt'), findsOneWidget);
    expect(find.text('.hidden'), findsNothing);
    expect(find.textContaining('符号链接'), findsOneWidget);
    expect(find.textContaining('644'), findsWidgets);
    expect(transport.execCalls, 0, reason: '文件功能不需要连接 DSH，也不跑远端命令');

    await tester.tap(_pageMenu());
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示隐藏文件'));
    await tester.pumpAndSettle();
    expect(find.text('.hidden'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('deleting asks first with the absolute path and only then removes', (tester) async {
    final files = _sampleFiles();
    await _pumpPage(tester, _Transport(files));

    await tester.tap(_moreOf('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('/notes.txt'), findsOneWidget, reason: '确认框必须显示绝对路径');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(files.removes, isEmpty);

    await tester.tap(_moreOf('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(files.removes, ['/notes.txt']);
    await _finish(tester);
  });

  testWidgets('changing permissions asks first and sends the octal mode', (tester) async {
    final files = _sampleFiles();
    await _pumpPage(tester, _Transport(files));

    await tester.tap(_moreOf('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('权限'));
    await tester.pumpAndSettle();
    expect(find.textContaining('立即'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '600');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(files.chmods, [('/notes.txt', 0x180)]);
    await _finish(tester);
  });

  testWidgets('renaming sends both absolute paths', (tester) async {
    final files = _sampleFiles();
    await _pumpPage(tester, _Transport(files));

    await tester.tap(_moreOf('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'renamed.txt');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(files.renames, [('/notes.txt', '/renamed.txt')]);
    await _finish(tester);
  });

  testWidgets('creating a folder sends the absolute path', (tester) async {
    final files = _sampleFiles();
    await _pumpPage(tester, _Transport(files));

    await tester.tap(_pageMenu());
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建文件夹'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'logs');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(files.madeDirs, ['/logs']);
    await _finish(tester);
  });

  testWidgets('a download shows its progress in the transfer sheet and can be cancelled', (tester) async {
    final files = _sampleFiles();
    files.bytes['/notes.txt'] = Uint8List.fromList(List.filled(600 * 1024, 65));
    files.readGate = Completer<void>();
    final container = await _pumpPage(tester, _Transport(files));
    final sftp = container.read(sftpProvider(_host).notifier);

    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('sftp-ui-dl-')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    late Future<void> future;
    await tester.runAsync(() async {
      future = sftp.download(remotePath: '/notes.txt', localPath: '${dir.path}/notes.txt');
    });
    await tester.runAsync(() async {
      while (container.read(sftpProvider(_host)).transfers.isEmpty ||
          container.read(sftpProvider(_host)).transfers.single.total == null) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    final transfer = container.read(sftpProvider(_host)).transfers.single;
    expect(transfer.upload, isFalse);
    expect(transfer.total, 600 * 1024);

    await tester.tap(_transfersButton());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('notes.txt'), findsWidgets);
    expect(find.textContaining(' / '), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.runAsync(() async {
      files.readGate!.complete();
      await future;
    });
    await tester.pump();
    expect(container.read(sftpProvider(_host)).transfers.single.status, SftpTransferStatus.cancelled);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已取消'), findsWidgets);
    await _finish(tester);
  });

  testWidgets('an upload is streamed in chunks and can be cancelled mid-way', (tester) async {
    final files = _Files(writeGateAt: 2);
    files.bytes['/notes.txt'] = Uint8List(0);
    files.listings['/'] = const [
      SshFileEntry(name: 'notes.txt', isDirectory: false, isSymbolicLink: false, size: 0, mode: 0x1A4),
    ];
    final container = await _pumpPage(tester, _Transport(files));
    final sftp = container.read(sftpProvider(_host).notifier);

    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('sftp-ui-ul-')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final local = File('${dir.path}/big.bin');
    late Future<void> future;
    await tester.runAsync(() async {
      local.writeAsBytesSync(List.filled(700 * 1024, 66));
      future = sftp.upload(localPath: local.path, remoteDir: '/');
    });
    await tester.runAsync(() async {
      while (container.read(sftpProvider(_host)).transfers.isEmpty ||
          files.writes.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    final transfer = container.read(sftpProvider(_host)).transfers.single;
    expect(transfer.upload, isTrue);
    expect(transfer.total, 700 * 1024);

    sftp.cancel(transfer.id);
    await tester.runAsync(() async {
      files.writeGate?.complete();
      await future;
    });
    final state = container.read(sftpProvider(_host)).transfers.single;
    expect(state.status, SftpTransferStatus.cancelled);
    expect(files.writes.length, lessThan(700 * 1024), reason: '不能一次把整个文件写进内存/网络');
    expect([for (final w in files.writes) w.$2], orderedEquals([for (final w in files.writes) w.$2]..sort()));
    expect(files.writes.first.$4, isTrue, reason: '第一块截断，之后按 offset 续写');
    await _finish(tester);
  });

  testWidgets('search finds files below the current directory without moving the browser', (tester) async {
    final files = _Files();
    files.listings['/'] = const [
      SshFileEntry(name: 'srv', isDirectory: true, isSymbolicLink: false, mode: 0x1ED),
      SshFileEntry(name: 'notes.txt', isDirectory: false, isSymbolicLink: false, size: 10, mode: 0x1A4),
    ];
    files.listings['/srv'] = const [
      SshFileEntry(name: 'app.txt', isDirectory: false, isSymbolicLink: false, size: 4, mode: 0x1A4),
    ];
    final container = await _pumpPage(tester, _Transport(files));

    await tester.tap(find.byTooltip('搜索文件名').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'app');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('/srv/app.txt'), findsOneWidget);
    expect(container.read(sftpProvider(_host)).path, '/', reason: '搜索不移动当前目录');
    await _finish(tester);
  });

  testWidgets('the star favorites the current directory and the panel lists it', (tester) async {
    final files = _Files();
    files.listings['/'] = const [
      SshFileEntry(name: 'notes.txt', isDirectory: false, isSymbolicLink: false, size: 10, mode: 0x1A4),
    ];
    await _pumpPage(tester, _Transport(files));

    await tester.tap(find.byTooltip('收藏此目录'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消收藏'), findsOneWidget);

    await tester.tap(_pageMenu());
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏夹'));
    await tester.pumpAndSettle();
    expect(find.text('还没有收藏的目录。在目录里点星号就能收藏。'), findsNothing);
    await _finish(tester);
  });

  testWidgets('copy asks for a destination and confirms before copying', (tester) async {
    final files = _sampleFiles();
    await _pumpPage(tester, _Transport(files));

    await tester.tap(_moreOf('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制到'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/backup');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('复制到「/backup/notes.txt」？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(files.writes, isEmpty, reason: '取消后不得复制');

    await tester.tap(_moreOf('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制到'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/backup');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '复制到'));
    await tester.pumpAndSettle();
    expect([for (final w in files.writes) w.$1], ['/backup/notes.txt']);
    await _finish(tester);
  });

  testWidgets('copying to the same place is refused without a request', (tester) async {
    final files = _sampleFiles();
    await _pumpPage(tester, _Transport(files));

    await tester.tap(_moreOf('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制到'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('目标与源是同一位置，换一个目录'), findsOneWidget);
    expect(files.writes, isEmpty);
    await _finish(tester);
  });

  testWidgets('move confirms and sends one server-side rename', (tester) async {
    final files = _sampleFiles();
    await _pumpPage(tester, _Transport(files));

    await tester.tap(_moreOf('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动到'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/backup');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('移动到「/backup/notes.txt」？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '移动到'));
    await tester.pumpAndSettle();
    expect(files.renames, [('/notes.txt', '/backup/notes.txt')]);
    await _finish(tester);
  });

  testWidgets('batch copy skips directories, asks first, and copies only files', (tester) async {
    final files = _Files();
    files.listings['/'] = const [
      SshFileEntry(name: 'srv', isDirectory: true, isSymbolicLink: false, mode: 0x1ED),
      SshFileEntry(name: 'notes.txt', isDirectory: false, isSymbolicLink: false, size: 10, mode: 0x1A4),
    ];
    files.bytes['/notes.txt'] = Uint8List.fromList('hello'.codeUnits);
    await _pumpPage(tester, _Transport(files));

    await tester.tap(_pageMenu());
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('srv'));
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 2 项'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '复制到'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/backup');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('复制到「/backup」？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '复制到'));
    await tester.pumpAndSettle();
    expect([for (final w in files.writes) w.$1], ['/backup/notes.txt'], reason: '目录跳过，只复制文件');
    await _finish(tester);
  });

  testWidgets('batch delete selects rows and removes only after the confirmation', (tester) async {
    final files = _sampleFiles();
    await _pumpPage(tester, _Transport(files));

    await tester.tap(_pageMenu());
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 1 项'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除选中的 1 项？'), findsOneWidget);
    expect(find.textContaining('/notes.txt'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(files.removes, ['/notes.txt']);
    await _finish(tester);
  });

  testWidgets('switching host stops 加入工作区 before it touches the other host', (tester) async {
    final files = _sampleFiles();
    final workspaces = _Workspaces();
    _workspacesFake = workspaces;
    final container = await _pumpPage(
      tester,
      _Transport(files),
      fixedHost: false,
      extra: [workspacesProvider.overrideWith(() => workspaces)],
    );

    // The person switches to another host while this host's file page stays open.
    container.read(activeHostProvider.notifier).select(const HostRef.ssh('pc'));
    await tester.pumpAndSettle();

    await tester.tap(_moreOf('srv'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入工作区'));
    await tester.pumpAndSettle();
    expect(_workspacesFake!.added, isEmpty, reason: '旧主机的页面不得把目录加入新主机的工作区');
    await _finish(tester);
  });

  testWidgets('switching host stops 加入对话附件 before any download starts', (tester) async {
    final files = _sampleFiles()..bytes['/notes.txt'] = Uint8List.fromList('hello'.codeUnits);
    final container = await _pumpPage(tester, _Transport(files), fixedHost: false);

    container.read(activeHostProvider.notifier).select(const HostRef.ssh('pc'));
    await tester.pumpAndSettle();

    await tester.tap(_moreOf('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入对话附件'));
    await tester.pumpAndSettle();
    expect(files.readRangeCalls, 0, reason: '换主机后不得从旧主机下载文件塞进新对话草稿');
    await _finish(tester);
  });

  testWidgets('a download finishing after a host switch leaves the new draft empty', (tester) async {
    final files = _sampleFiles();
    files.bytes['/notes.txt'] = Uint8List.fromList(List.filled(600 * 1024, 65));
    files.readGate = Completer<void>();
    final container = await _pumpPage(tester, _Transport(files), fixedHost: false);

    final root = Directory.systemTemp.createTempSync('sftp-ui-attach-');
    addTearDown(() => root.deleteSync(recursive: true));
    final previous = PathProviderPlatform.instance;
    addTearDown(() => PathProviderPlatform.instance = previous);
    useTempRoot(root.path);

    Iterable<File> scratch() => Directory('${root.path}/sftp')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('/notes.txt'));

    await tester.tap(_moreOf('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入对话附件'));
    await tester.pump();

    // The handler builds its scratch folder on disk and the transfer writes
    // there too; that real file IO only advances when the real event loop gets
    // a turn, so every step alternates runAsync (real IO) with pump (fake zone).
    await _stepUntil(tester, () => files.readRangeCalls >= 2);
    expect(files.readRangeCalls, greaterThanOrEqualTo(2), reason: '下载必须真的开始并在中途被挡住');
    expect(scratch(), hasLength(1), reason: '第一块已经落到这次下载自己的临时文件');

    // The person switches host while the download is still running.
    container.read(activeHostProvider.notifier).select(const HostRef.ssh('pc'));
    await tester.pump();

    files.readGate!.complete();
    await _stepUntil(tester, () => scratch().isEmpty, cycles: 600);
    await tester.pump(const Duration(milliseconds: 50));

    expect(scratch(), isEmpty, reason: '切主机后这份临时下载必须删掉，不能留在缓存里');
    expect(
      container.read(composeInboxProvider),
      isEmpty,
      reason: '下载完成时主机已经不是被打开的那台，草稿不得新增',
    );
    expect(find.textContaining('主机已切换'), findsWidgets, reason: '要告诉用户这次操作没有执行');
    expect(find.byType(ServerFilesPage), findsOneWidget, reason: '失败路径不能把页面关掉');
    await _finish(tester);
  });

  testWidgets('a download finishing on the same host lands in the new draft', (tester) async {
    final files = _sampleFiles();
    files.bytes['/notes.txt'] = Uint8List.fromList(List.filled(300 * 1024, 66));
    final container = await _pumpPage(tester, _Transport(files), fixedHost: false);

    final root = Directory.systemTemp.createTempSync('sftp-ui-attach-ok-');
    addTearDown(() => root.deleteSync(recursive: true));
    final previous = PathProviderPlatform.instance;
    addTearDown(() => PathProviderPlatform.instance = previous);
    useTempRoot(root.path);

    await tester.tap(_moreOf('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入对话附件'));
    await tester.pump();

    await _stepUntil(
      tester,
      () => container.read(composeInboxProvider).isNotEmpty,
      cycles: 600,
    );
    await tester.pump(const Duration(milliseconds: 50));

    final request = container.read(composeInboxProvider).single;
    expect(request.attachments.single.name, 'notes.txt');
    expect(request.attachments.single.size, 300 * 1024);
    expect(find.textContaining('主机已切换'), findsNothing, reason: '主机没变，不该报错');
    await _finish(tester);
  });

  testWidgets('text preview saves only after the overwrite confirmation', (tester) async {
    final files = _sampleFiles()..bytes['/notes.txt'] = Uint8List.fromList(utf8.encode('hello sftp'));
    await _pumpPage(tester, _Transport(files));

    // Opening the file from the browser shares the already-connected session.
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    expect(find.byType(ServerFilePreviewPage), findsOneWidget);
    expect(find.textContaining('hello sftp', findRichText: true), findsOneWidget);
    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hello world');
    await tester.pump();
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存并覆盖？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(files.writes, isEmpty, reason: '取消后不得覆盖服务器文件');

    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(files.writes.single.$1, '/notes.txt');
    expect(files.writes.single.$4, isTrue);
    expect(files.writes.single.$5, 'hello world');
    await _finish(tester);
  });

  testWidgets('a lost connection turns the page into a retryable failure', (tester) async {
    final transport = _Transport(_sampleFiles());
    final container = await _pumpPage(tester, transport);
    transport.close();
    await tester.pumpAndSettle();
    expect(container.read(sftpProvider(_host)).phase, SftpPhase.failed);
    expect(find.textContaining('连接已断开'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
    await _finish(tester);
  });
}
