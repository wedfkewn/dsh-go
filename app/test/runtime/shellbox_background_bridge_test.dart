import 'dart:async';

import 'package:dsh_app/runtime/shellbox/shellbox_runtime_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/shellbox');
  const codec = StandardMethodCodec();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<Object?> nativeCall(String method, Map<String, Object?> task) async {
    final reply = Completer<Object?>();
    await messenger.handlePlatformMessage(channel.name, codec.encodeMethodCall(MethodCall(method, task)), (data) {
      reply.complete(data == null ? null : codec.decodeEnvelope(data));
    });
    return reply.future;
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
  });

  test('late cancellation for a retired task cannot cancel the replacement', () async {
    final bridge = ShellBoxRuntimeBridge();
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    var canceled = 0;
    final old = <String, Object?>{
      'runtimeInstanceId': 'instance-a', 'sessionId': 'session', 'taskId': 'turn-1', 'status': 'running',
    };
    await bridge.updateActiveTask(old, () async { canceled += 1; return true; });
    final next = {...old, 'taskId': 'turn-2'};
    await bridge.updateActiveTask(next, () async { canceled += 10; return true; });
    expect(await nativeCall('cancelBackgroundTask', old), 'unconfirmed');
    expect(canceled, 0);
    expect(await nativeCall('cancelBackgroundTask', next), 'accepted');
    expect(canceled, 10);
  });

  test('native authorization expiry is delivered without stopping ShellBox', () async {
    final bridge = ShellBoxRuntimeBridge();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async { calls.add(call.method); return null; });
    final event = bridge.backgroundChanges.first;
    await nativeCall('backgroundExecutionChanged', {
      'runtimeInstanceId': 'instance-a', 'state': 'expired', 'runtimePhase': 'stopBlocked',
      'authorizationActive': false,
    });
    expect((await event)['runtimePhase'], 'stopBlocked');
    expect(calls, isEmpty);
  });

  test('system rejection is returned unchanged on the existing channel', () async {
    final bridge = ShellBoxRuntimeBridge();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'requestContinuedProcessing');
      return 'scheduler_rejected_1';
    });
    expect(await bridge.requestContinuedProcessing(), 'scheduler_rejected_1');
  });
}
