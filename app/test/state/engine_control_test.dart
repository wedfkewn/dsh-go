import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/shellbox/shellbox_runtime_bridge.dart';
import 'package:flutter/services.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/engine_control.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safe_mode/support.dart';

class _Runtime extends RecordingRuntime {
  _Runtime(super.initial, this.calls);
  final List<String> calls;

  @override
  Future<void> stop() {
    calls.add('stop');
    return super.stop();
  }

  @override
  Future<void> start() async {
    calls.add('start');
    await super.start();
  }

  @override
  Future<void> startIn(EngineMode mode) async {
    calls.add(mode.name);
    await super.startIn(mode);
  }
}

class _Bridge extends FakeBridge {
  _Bridge(this.order);
  final List<String> order;
  @override
  Future<LastKnownGood> restoreLastKnownGood() async {
    order.add('restore');
    return const LastKnownGood.none();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final nativePhase in [RuntimePhase.running, RuntimePhase.stopped, RuntimePhase.stopBlocked]) {
    test('resume reads native ${nativePhase.name} before any start decision', () async {
      const channel = MethodChannel('dsh/shellbox');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'status') return {'phase': nativePhase.name};
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final calls = <String>[];
      // Deliberately stale Dart state: foreground must replace this snapshot.
      final runtime = _Runtime(const LocalRuntimeState(status: RuntimeStatus(phase: RuntimePhase.error)), calls);
      final container = ProviderContainer(
        overrides: [
          localRuntimeProvider.overrideWith(() => runtime),
          runtimeBridgeProvider.overrideWithValue(ShellBoxRuntimeBridge(channel: channel)),
        ],
      );
      addTearDown(container.dispose);
      container.read(localRuntimeProvider);
      final status = await runtime.resumeFromNative();
      expect(status.phase, nativePhase);
      expect(container.read(localRuntimeProvider).status.phase, nativePhase);
      expect(methods, ['appLifecycle', 'status']);
      expect(calls, isEmpty); // Resume itself never restarts.
      await EngineControl.ensureStarted(container, source: 'test.resume');
      expect(calls, nativePhase == RuntimePhase.stopped ? ['start'] : isEmpty);
      expect(methods.where((method) => method == 'stop' || method == 'restart'), isEmpty);
    });
  }

  LocalRuntimeState phase(RuntimePhase phase) => LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: phase));

  test('StopBlocked refuses restart without starting another instance', () async {
    final calls = <String>[];
    final runtime = _Runtime(phase(RuntimePhase.stopBlocked), calls);
    final container = ProviderContainer(overrides: [localRuntimeProvider.overrideWith(() => runtime)]);
    addTearDown(container.dispose);
    expect(await EngineControl.restart(container), isFalse);
    expect(calls, isEmpty);
  });

  test('restart already stopping waits for installed without another stop', () async {
    final calls = <String>[];
    final runtime = _Runtime(phase(RuntimePhase.stopping), calls);
    final container = ProviderContainer(overrides: [localRuntimeProvider.overrideWith(() => runtime)]);
    addTearDown(container.dispose);
    final restarting = EngineControl.restart(container);
    expect(runtime.stops, 0);
    expect(calls, isEmpty);
    runtime.emit(phase(RuntimePhase.installed));
    await restarting;
    expect(calls, ['start']);
  });

  test('safe mode restore precedes stop and normal start', () async {
    final calls = <String>[];
    final runtime = _Runtime(LocalRuntimeState(loaded: true, status: safeStatus()), calls);
    final container = ProviderContainer(
      overrides: [
        localRuntimeProvider.overrideWith(() => runtime),
        runtimeBridgeProvider.overrideWithValue(_Bridge(calls)),
      ],
    );
    addTearDown(container.dispose);
    await EngineControl.restoreLastKnownGood(container);
    expect(calls, ['restore', 'stop', 'normal']);
  });
}
