// P1 host isolation: every list read and every write (workspaces, model
// catalog, provider credentials) goes through `readListLiveConnectionProvider`,
// which admits a connection only when its kind — and, for remotes, its hostId —
// matches the host the person selected. A selected remote that is not connected
// falls back to no source at all, never to the on-device engine.
//
// Workspace removal is a registry edit only: the app must send
// `workspace/delete` and nothing that touches a folder, and the folder, its
// conversations and the recently-picked path stay.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart' show FakeRuntime, FakeSettings, runningStatus;
import '../workspace/support.dart';

/// A host that also answers the model-catalog and credential endpoints the
/// provider/model screens use, recording each call in [calls].
class _TargetHost extends FakeWorkspaceHost {
  _TargetHost({super.folders});

  final List<Map<String, Object?>> credentialWrites = [];

  static final catalog = {
    'groups': [
      {
        'id': 'deepseek-official',
        'name': 'DeepSeek',
        'models': [
          {'id': 'deepseek-v4-pro', 'name': 'V4 Pro'},
        ],
      },
    ],
    'default': {'provider': 'deepseek-official', 'model': 'deepseek-v4-pro'},
    'routableProviders': ['deepseek-official'],
    'failures': <Object?>[],
  };

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) {
    switch (endpoint) {
      case 'session/modelCatalog':
        calls.add((endpoint, args));
        return Future.value(RpcOk(catalog));
      case 'credentials/set':
        calls.add((endpoint, args));
        credentialWrites.add(args);
        return Future.value(const RpcOk({'ok': true}));
      case 'credentials/unset':
        calls.add((endpoint, args));
        return Future.value(const RpcOk({'ok': true}));
      case 'settings/describe':
        calls.add((endpoint, args));
        return Future.value(const RpcOk({'namespaces': [], 'writable': true}));
    }
    return super.call(endpoint, args, timeout: timeout);
  }
}

/// The connection the app would show as active; a test switches it to model a
/// reconnect or a host change without a real SSH link.
class _Swap extends Notifier<AsyncValue<HostConnection?>> {
  _Swap(this.initial);

  final AsyncValue<HostConnection?> initial;

  @override
  AsyncValue<HostConnection?> build() => initial;

  void set(HostConnection? connection) => state = AsyncData(connection);
}

final _swapProvider = NotifierProvider<_Swap, AsyncValue<HostConnection?>>(
  () => throw StateError('overridden per container'),
);

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

bool _touchesFiles(String endpoint) =>
    RegExp(r'^(files?|fs)/').hasMatch(endpoint) ||
    endpoint.contains('deleteFile') ||
    endpoint.contains('removeFile') ||
    endpoint.contains('rmdir');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TargetHost remote;
  late _TargetHost localHost;

  ProviderContainer containerFor(AsyncValue<HostConnection?> initial) {
    final c = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWith((ref) => ref.watch(_swapProvider)),
        _swapProvider.overrideWith(() => _Swap(initial)),
        localRuntimeProvider.overrideWith(
          () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
        ),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true, apiKey: 'sk-phone'))),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    remote = _TargetHost(folders: ['/srv/app', '/srv/other']);
    localHost = _TargetHost(folders: ['/root/workspace']);
    remote.seedWorkspace('/srv/app', sessionIds: ['s1']);
    remote.seedSession('s1', '远程会话', DateTime.utc(2026, 10, 24));
    localHost.seedWorkspace('/root/workspace', sessionIds: ['l1']);
  });

  test('remote selected: workspaces, model catalog and credential writes reach the remote only', () async {
    final conn = workspaceHost(remote, local: false);
    final c = containerFor(AsyncData(conn));
    c.read(activeHostProvider.notifier).select(HostRef.ssh('pc'));
    addTearDown(() => c.read(activeHostProvider.notifier).select(HostRef.local));

    final workspaces = c.listen(workspacesProvider, (_, _) {});
    addTearDown(workspaces.close);
    final catalog = c.listen(modelCatalogProvider, (_, _) {});
    addTearDown(catalog.close);
    await _settle();

    expect(c.read(workspacesProvider).ready, isTrue);
    expect([for (final w in c.read(workspacesProvider).workspaces) w.path], ['/srv/app']);
    expect(remote.argsOf('session/modelCatalog'), isNotEmpty);
    expect(c.read(modelCatalogProvider).value!.groups.single.id, 'deepseek-official');

    final notifier = c.read(workspacesProvider.notifier);
    final added = await notifier.add('/srv/other');
    await notifier.rename(added.workspaceId, '另一个');
    await notifier.remove(added.workspaceId);
    await _settle();

    expect(remote.argsOf('workspace/create').single, {
      'request': {'path': '/srv/other'},
    });
    expect(remote.argsOf('workspace/rename').single, {
      'request': {'workspaceId': added.workspaceId, 'title': '另一个'},
    });
    expect(remote.argsOf('workspace/delete').single, {
      'request': {'workspaceId': added.workspaceId},
    });

    // A remote config write (the API key typed on the provider screen) lands on
    // the remote host; the phone's own key never crosses over.
    final backend = c.read(providerBackendProvider)!;
    expect(backend.isLocal, isFalse);
    await backend.storeKey('DEEPSEEK_API_KEY', 'sk-remote');
    expect(remote.credentialWrites.single, {'ref': 'DEEPSEEK_API_KEY', 'value': 'sk-remote'});

    expect(localHost.calls, isEmpty, reason: '本机引擎不应收到任何远程工作区/模型/凭据调用');
  });

  test('a selected host with no matching connection has no source, never the other engine', () async {
    // 远程选中，但连接仍是本机（重连失败后的回落、或宿主列表未知）。
    final c = containerFor(AsyncData(workspaceHost(localHost)));
    c.read(activeHostProvider.notifier).select(HostRef.ssh('pc'));
    addTearDown(() => c.read(activeHostProvider.notifier).select(HostRef.local));

    expect(readListConnection(c.read(activeConnectionProvider), const HostRef.ssh('pc')), isNull);
    expect(c.read(readListLiveConnectionProvider), isNull);
    expect(c.read(providerBackendProvider), isNull);
    expect(c.read(workspacesProvider).status, WorkspacesStatus.offline);
    expect(c.read(modelCatalogProvider).value, isNull);
    await _settle();
    expect(localHost.calls, isEmpty, reason: '回落不能被当成本机数据源');
    expect(remote.calls, isEmpty);
  });

  test('engine settings read the selected host, never the on-device engine', () async {
    final c = containerFor(AsyncData(workspaceHost(remote, local: false)));
    c.read(activeHostProvider.notifier).select(HostRef.ssh('pc'));
    addTearDown(() => c.read(activeHostProvider.notifier).select(HostRef.local));
    final settings = c.listen(engineSettingsProvider, (_, _) {});
    addTearDown(settings.close);
    await _settle();

    expect(remote.argsOf('settings/describe'), isNotEmpty, reason: '设置页要读选中的那台主机');
    expect(c.read(engineSettingsProvider).value, isNotNull);
    expect(localHost.calls, isEmpty, reason: '本机引擎不得被设置页读取');
  });

  test('a selected host that is not loaded never reads or writes phone settings', () async {
    // 远程选中，但当前连接仍属于本机：身份不符，设置页必须既没有来源也不能写。
    final c = containerFor(AsyncData(workspaceHost(localHost)));
    c.read(activeHostProvider.notifier).select(HostRef.ssh('pc'));
    addTearDown(() => c.read(activeHostProvider.notifier).select(HostRef.local));
    final settings = c.listen(engineSettingsProvider, (_, _) {});
    addTearDown(settings.close);
    await _settle();

    expect(c.read(activeWriteConnectionProvider), isNull, reason: '没有与选中主机匹配的连接');
    expect(c.read(engineSettingsProvider).value, isNull, reason: '设置页没有来源');
    expect(localHost.argsOf('settings/describe'), isEmpty, reason: '不得读本机设置');
    expect(remote.argsOf('settings/describe'), isEmpty);
  });

  test('a local selection never reuses a remote connection', () async {
    final c = containerFor(AsyncData(workspaceHost(remote, local: false)));
    expect(c.read(activeHostProvider).isLocal, isTrue);

    expect(readListConnection(c.read(activeConnectionProvider), HostRef.local), isNull);
    expect(c.read(readListLiveConnectionProvider), isNull);
    expect(c.read(providerBackendProvider), isNull);
    await _settle();
    expect(localHost.calls, isEmpty);
    expect(remote.calls, isEmpty);
  });

  test('a connection for another SSH hostId is not accepted for the selected host', () async {
    final c = containerFor(AsyncData(workspaceHost(remote, local: false))); // hostId 'pc'
    c.read(activeHostProvider.notifier).select(const HostRef.ssh('other-pc'));
    addTearDown(() => c.read(activeHostProvider.notifier).select(HostRef.local));

    expect(readListConnection(c.read(activeConnectionProvider), const HostRef.ssh('other-pc')), isNull);
    expect(c.read(readListLiveConnectionProvider), isNull);
    await _settle();
    expect(remote.calls, isEmpty);
  });

  test('switching host retargets writes: the remote is left untouched', () async {
    final remoteConn = workspaceHost(remote, local: false);
    final localConn = workspaceHost(localHost);
    final c = containerFor(AsyncData(remoteConn));
    c.read(activeHostProvider.notifier).select(HostRef.ssh('pc'));
    final workspaces = c.listen(workspacesProvider, (_, _) {});
    addTearDown(workspaces.close);
    await _settle();
    await c.read(providerBackendProvider)!.storeKey('DEEPSEEK_API_KEY', 'sk-remote');
    expect(remote.credentialWrites, hasLength(1));
    expect(localHost.calls, isEmpty);

    // 切回本机：真实栈里 connection provider 会重建。
    c.read(activeHostProvider.notifier).select(HostRef.local);
    c.read(_swapProvider.notifier).set(localConn);
    await _settle();

    expect(c.read(readListLiveConnectionProvider)!.isLocal, isTrue);
    await c.read(providerBackendProvider)!.storeKey('DEEPSEEK_API_KEY', 'sk-local');
    expect(localHost.credentialWrites.single, {'ref': 'DEEPSEEK_API_KEY', 'value': 'sk-local'});
    expect(remote.credentialWrites, hasLength(1), reason: '切回本机后不得再写远程');
  });

  test('session writes never fall back to the other engine', () async {
    // 远程主机被选中，但连接回落成本机（宿主列表未知/重连失败）：会话写入
    // 不能因此打到本机引擎。目前这条是红的，等生产代码改用 live 连接。
    final c = containerFor(AsyncData(workspaceHost(localHost)));
    c.read(activeHostProvider.notifier).select(HostRef.ssh('pc'));
    addTearDown(() => c.read(activeHostProvider.notifier).select(HostRef.local));
    await _settle();

    final sessions = c.read(sessionsProvider.notifier);
    await sessions.rename('l1', 'x').catchError((Object _) {});
    await sessions.archive('l1').catchError((Object _) {});
    await sessions.create().then<void>((_) {}, onError: (Object _) {});

    final written = [
      for (final (e, _) in localHost.calls)
        if (e == 'session/rename' || e == 'session/create' || e == 'workspace/archiveSession') e,
    ];
    expect(written, isEmpty, reason: '选中的是远程主机，会话写入不得落到本机引擎');
  });

  test('removing a workspace unregisters it and leaves the folder and conversations intact', () async {
    final dir = await Directory.systemTemp.createTemp('dsh-ws-remove-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    remote.folders.add(dir.path);
    final ws = remote.seedWorkspace(dir.path, title: '要移除的', sessionIds: ['s1']);
    final wsId = ws['workspaceId'] as String;
    SharedPreferences.setMockInitialValues({
      'workspaces.ssh.pc': jsonEncode({
        'selected': wsId,
        'pinned': [wsId],
        'groups': {wsId: '工作'},
        'recent': [dir.parent.path],
      }),
    });

    final c = containerFor(AsyncData(workspaceHost(remote, local: false)));
    c.read(activeHostProvider.notifier).select(HostRef.ssh('pc'));
    addTearDown(() => c.read(activeHostProvider.notifier).select(HostRef.local));
    final workspaces = c.listen(workspacesProvider, (_, _) {});
    addTearDown(workspaces.close);
    final prefs = c.listen(workspacePrefsProvider, (_, _) {});
    addTearDown(prefs.close);
    await _settle();
    expect(c.read(workspacePrefsProvider).loaded, isTrue);
    expect(c.read(workspacePrefsProvider).selected, wsId);

    await c.read(workspacesProvider.notifier).remove(wsId);
    await _settle();

    // 只发登记移除，没有任何触碰文件的调用。
    final endpoints = [for (final (e, _) in remote.calls) e];
    expect(endpoints.where(_touchesFiles), isEmpty);
    expect(remote.argsOf('workspace/delete').single, {
      'request': {'workspaceId': wsId},
    });
    expect(remote.workspaces.map((w) => w['workspaceId']), isNot(contains(wsId)));
    expect(c.read(workspacesProvider).byId(wsId), isNull);

    // 远端文件夹、会话和本机最近目录都还在；重新登记会得到 created=true 而不是旧登记。
    expect(await dir.exists(), isTrue);
    expect(remote.folders, contains(dir.path));
    expect(remote.sessions.map((s) => s['sessionId']), contains('s1'));
    final again = await c.read(workspacesProvider.notifier).add(dir.path);
    expect(remote.argsOf('workspace/create').last, {
      'request': {'path': dir.path},
    });
    expect(again.path, dir.path);

    // 手机侧视图忘了它：选中、置顶、分组清除，最近目录保留。
    final view = c.read(workspacePrefsProvider);
    expect(view.selected, isNull);
    expect(view.pinned, isEmpty);
    expect(view.groups, isEmpty);
    expect(view.recent, [dir.parent.path]);
    expect(localHost.calls, isEmpty);
  });
}
