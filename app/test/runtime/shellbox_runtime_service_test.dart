import 'dart:async';

import 'package:dsh_app/runtime/local_runtime_service.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/shellbox/shellbox_runtime_bridge.dart';
import 'package:dsh_app/runtime/shellbox/shellbox_runtime_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/shellbox');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final service = ShellBoxRuntimeService();

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('lifecycle preserves native operation-specific failures', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'shellbox_${call.method}_unimplemented');
    });
    for (final operation in <String, Future<void> Function()>{
      'start': service.start,
      'stop': service.stop,
      'restart': service.restart,
    }.entries) {
      await expectLater(
        operation.value(),
        throwsA(isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'shellbox_${operation.key}_unimplemented',
        )),
      );
    }
    expect(calls, ['start', 'stop', 'restart']);
  });

  test('status reflects native error without asserting readiness', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'status');
      return {
        'phase': 'unimplemented',
        'error': {
          'code': 'shellbox_start_rootfs_unimplemented',
          'message': 'No prepared payload.',
        },
      };
    });
    final status = await service.status();
    expect(status.phase, LocalRuntimeServicePhase.unimplemented);
    expect(status.error?.code, 'shellbox_start_rootfs_unimplemented');
    expect(status.error?.message, 'No prepared payload.');
  });

  test('app adapter uses ShellBox start and names unsupported operations', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'shellbox_${call.method}_unimplemented');
    });
    final bridge = ShellBoxRuntimeBridge(service: service);
    await expectLater(bridge.start(), throwsA(isA<PlatformException>().having(
      (e) => e.code, 'code', 'shellbox_start_unimplemented',
    )));
    await expectLater(bridge.install(), throwsA(isA<PlatformException>().having(
      (e) => e.code, 'code', 'shellbox_install_unimplemented',
    )));
    await expectLater(bridge.storageStatus(), throwsA(isA<PlatformException>().having(
      (e) => e.code, 'code', 'shellbox_storageStatus_unimplemented',
    )));
  });

  test('real status phases are accepted', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {'phase': 'running'});
    expect((await service.status()).phase, LocalRuntimeServicePhase.running);
  });

  test('bridge preserves status fields and maps the scaffold error', () async {
    var phase = 'running';
    messenger.setMockMethodCallHandler(channel, (_) async => {
      'phase': phase,
      'baseUrl': 'http://127.0.0.1:3080',
      'token': 'test-token',
      'installedVersion': 'test-version',
      'mode': 'safe',
      'failure': {'kind': 'killed', 'at': 123},
      'error': {'code': 'shellbox_test_error', 'message': 'Test failure'},
    });
    final bridge = ShellBoxRuntimeBridge();
    final status = await bridge.status();
    expect(status.isRunning, isTrue);
    expect(status.installedVersion, 'test-version');
    expect(status.mode, EngineMode.safe);
    expect(status.failure?.kind, FailureKind.killed);
    phase = 'unimplemented';
    final legacy = await bridge.status();
    expect(legacy.phase, RuntimePhase.error);
    expect(legacy.error, 'shellbox_test_error: Test failure');
  });

  test('install reset and logs use the native contract', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'logs') return ['line'];
      if (call.method == 'logSnapshot') {
        return {
          'entries': [{'seq': 7, 'line': 'line', 'stream': 'stdout'}],
          'throughSeq': 7,
        };
      }
      return null;
    });
    final bridge = ShellBoxRuntimeBridge();
    await bridge.install(dropKept: true);
    await bridge.reset(keep: ResetKeep.suggested);
    expect(await bridge.logs(lines: 12), ['line']);
    final snapshot = await bridge.logSnapshot(lines: 13);
    expect(snapshot.throughSeq, 7);
    expect(snapshot.entries.single.line, 'line');
    expect(calls.map((c) => c.method), ['install', 'reset', 'logs', 'logSnapshot']);
    expect(calls.map((c) => c.arguments), [
      {'dropKept': true}, {'keep': ['uiAndSkills']}, {'lines': 12}, {'lines': 13},
    ]);
  });

  test('missing native handlers fail by operation name', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => throw MissingPluginException());
    final bridge = ShellBoxRuntimeBridge();
    for (final operation in <String, Future<dynamic> Function()>{
      'install': () => bridge.install(),
      'reset': () => bridge.reset(),
      'logs': () => bridge.logs(),
      'logSnapshot': () => bridge.logSnapshot(),
      'clearFailure': () => bridge.clearFailure(),
      'networkMetered': () => bridge.networkMetered(),
      'openVendorSettings': () => bridge.openVendorSettings('autostart'),
    }.entries) {
      await expectLater(operation.value(), throwsA(isA<PlatformException>().having(
        (e) => e.code, 'code', 'shellbox_${operation.key}_unimplemented',
      )));
    }
  });

  testWidgets('polling deduplicates, emits notices, cancels and resumes', (tester) async {
    var phase = 'starting';
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return {'phase': phase, if (calls == 1) 'notices': ['Preparing']};
    });
    final bridge = ShellBoxRuntimeBridge();
    final events = <RuntimeEvent>[];
    StreamSubscription<RuntimeEvent> subscription = bridge.events.listen(events.add);
    await tester.pump();
    expect(events.whereType<RuntimeStatusEvent>().single.status.phase, RuntimePhase.starting);
    expect(events.whereType<RuntimeNoticeEvent>().single.text, 'Preparing');
    await tester.pump(const Duration(seconds: 1));
    expect(events.whereType<RuntimeStatusEvent>().length, 1);
    phase = 'running';
    await tester.pump(const Duration(seconds: 1));
    expect(events.whereType<RuntimeStatusEvent>().last.status.phase, RuntimePhase.running);
    await subscription.cancel();
    final stoppedAt = calls;
    await tester.pump(const Duration(seconds: 2));
    expect(calls, stoppedAt);
    subscription = bridge.events.listen(events.add);
    await tester.pump();
    expect(calls, stoppedAt + 1);
    await subscription.cancel();
  });

}
