import 'package:flutter/services.dart';

import '../runtime_bridge.dart';
import 'shellbox_runtime_service.dart';

/// Adapts the existing local UI to the Stage 3 lifecycle. No Android channel
/// is used for iOS status/start/stop or installation.
class ShellBoxRuntimeBridge extends RuntimeBridge {
  ShellBoxRuntimeBridge({ShellBoxRuntimeService? service})
    : _service = service ?? ShellBoxRuntimeService(),
      super(methods: const _UnavailableShellBoxChannel());
  final ShellBoxRuntimeService _service;

  @override
  Stream<RuntimeEvent> get events => const Stream.empty();

  @override
  Future<RuntimeStatus> status() async {
    final status = await _service.status();
    return RuntimeStatus(phase: RuntimePhase.error, error: '${status.error?.code}: ${status.error?.message}');
  }

  @override
  Future<void> start({Map<String, String> env = const {}, bool phoneStorage = false,
    EngineMode? mode, bool visualReplies = true}) => _service.start();

  @override
  Future<void> stop() => _service.stop();

  @override
  Future<void> install({bool dropKept = false}) async => throw PlatformException(code: 'shellbox_install_rootfs_unimplemented');

  @override
  Future<void> reset({ResetKeep keep = const ResetKeep()}) async => throw PlatformException(code: 'shellbox_reset_unimplemented');

  @override
  Future<List<String>> logs({int lines = 500}) async => throw PlatformException(code: 'shellbox_logs_unimplemented');

  @override
  Future<RuntimeLogSnapshot> logSnapshot({int lines = 300}) async => throw PlatformException(code: 'shellbox_log_snapshot_unimplemented');
}

/// Inherited Android-only operations must fail by operation name on iOS.
class _UnavailableShellBoxChannel extends MethodChannel {
  const _UnavailableShellBoxChannel() : super('dsh/shellbox/unavailable');

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    throw PlatformException(code: 'shellbox_${method}_unimplemented');
  }
}
