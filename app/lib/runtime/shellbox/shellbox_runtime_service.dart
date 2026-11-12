import 'package:flutter/services.dart';

import '../local_runtime_service.dart';

/// Native iOS boundary. PlatformException codes describe incomplete operations;
/// directory creation is never treated as successful runtime startup.
final class ShellBoxRuntimeService implements LocalRuntimeService {
  ShellBoxRuntimeService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dsh/shellbox');

  final MethodChannel _channel;

  @override
  Future<void> start() => _channel.invokeMethod<void>('start');

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');

  @override
  Future<void> restart() => _channel.invokeMethod<void>('restart');

  @override
  Future<LocalRuntimeServiceStatus> status() async {
    final response = await _channel.invokeMapMethod<String, dynamic>('status');
    if (response == null || response['phase'] != 'unimplemented') {
      throw PlatformException(
        code: 'shellbox_status_invalid_response',
        message: 'Native ShellBox returned an unsupported status.',
      );
    }
    final error = response['error'];
    if (error is! Map || error['code'] is! String || error['message'] is! String) {
      throw PlatformException(
        code: 'shellbox_status_invalid_response',
        message: 'Native ShellBox returned an invalid error.',
      );
    }
    return LocalRuntimeServiceStatus(
      phase: LocalRuntimeServicePhase.unimplemented,
      error: LocalRuntimeServiceError(
        error['code'] as String,
        error['message'] as String,
      ),
    );
  }
}
