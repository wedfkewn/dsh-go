import 'package:flutter/services.dart';

import '../runtime_bridge.dart';
import 'native_node_runtime_service.dart';

/// Opt-in adapter for the native iOS backend. The Android and ShellBox
/// channels are owned by their respective runtimes.
final class NativeNodeRuntimeBridge extends RuntimeBridge {
  NativeNodeRuntimeBridge({
    MethodChannel methods = const MethodChannel('dsh/native_node'),
    EventChannel events = const EventChannel('dsh/native_node/events'),
  }) : _service = NativeNodeRuntimeService(channel: methods),
       super(methods: methods, events: events);

  final NativeNodeRuntimeService _service;

  @override
  Future<RuntimeStatus> status() async {
    final raw = await _service.statusMap();
    final error = raw['error'];
    return RuntimeStatus.fromMap({...raw, 'error': error is Map ? '${error['code']}: ${error['message']}' : error});
  }
}
