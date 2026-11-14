import 'package:flutter/services.dart';

import '../local_runtime_service.dart';

/// Fail-closed iOS NodeMobile runtime boundary.
///
/// The native component must first prove a live, authenticated loopback
/// DSH endpoint before reporting a running status.
/// No guest filesystem, process, or user data is modified by this adapter.
final class NativeNodeRuntimeService implements LocalRuntimeService {
  NativeNodeRuntimeService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dsh/native_node');

  final MethodChannel _channel;

  PlatformException get _notLinked => PlatformException(
    code: 'native_node_not_linked',
    message: 'The iOS native Node runtime has not been linked.',
  );

  PlatformException get _invalidStatus => PlatformException(
    code: 'native_node_status_invalid_response',
    message: 'Native Node returned an invalid or unverified status.',
  );

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      throw _notLinked;
    }
  }

  @override
  Future<void> start() => _invoke('start');

  @override
  Future<void> stop() => _invoke('stop');

  @override
  Future<void> restart() => _invoke('restart');

  /// Keep optional fields available for a future RuntimeBridge adapter.
  /// A phase of running is invalid without a reachable local endpoint and
  /// a nonempty access token. Never promote "starting" to "running".
  Future<Map<String, dynamic>> statusMap() async {
    Map<String, dynamic>? response;
    try {
      response = await _channel.invokeMapMethod<String, dynamic>('status');
    } on MissingPluginException {
      throw _notLinked;
    }
    if (response == null) throw _invalidStatus;

    final phase = response['phase'];
    if (phase is! String ||
        !LocalRuntimeServicePhase.values.any((value) => value.name == phase)) {
      throw _invalidStatus;
    }

    final error = response['error'];
    if (error is! String && error != null &&
        (error is! Map || error['code'] is! String || error['message'] is! String)) {
      throw _invalidStatus;
    }

    if (phase == 'running') {
      final address = response['baseUrl'];
      final token = response['token'];
      final uri = address is String ? Uri.tryParse(address) : null;
      if (uri == null ||
          uri.scheme != 'http' ||
          !uri.hasPort ||
          uri.port == 0 ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          !{'127.0.0.1', '::1', 'localhost'}.contains(uri.host) ||
          token is! String ||
          token.trim().isEmpty) {
        throw _invalidStatus;
      }
    }

    return response;
  }

  @override
  Future<LocalRuntimeServiceStatus> status() async {
    final result = await statusMap();
    final phase = LocalRuntimeServicePhase.values.firstWhere(
      (item) => item.name == result['phase'],
    );
    final error = result['error'];
    return LocalRuntimeServiceStatus(
      phase: phase,
      error: switch (error) {
        final Map value => LocalRuntimeServiceError(
          value['code'] as String,
          value['message'] as String,
        ),
        final String message =>
          LocalRuntimeServiceError('native_node_runtime_error', message),
        _ => null,
      },
    );
  }
}
