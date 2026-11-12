import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../runtime_bridge.dart';
import 'shellbox_runtime_service.dart';

/// UI adapter for MethodChannel `dsh/shellbox`.
///
/// Native contract (also docs/ios/shellbox-channel-contract.md):
/// - status(): RuntimeStatus map; error may be String or {code, message}.
///   Optional notices: List<String>, drained by native on each status call.
/// - start({env, phoneStorage, mode, visualReplies}), stop(), restart(): null.
/// - install(null or {dropKept: true}): null, only after installation completes.
/// - reset({keep: List<String>}): null; keep is ResetKeep.wire.
/// - logs({lines: int}): List<String>.
/// - logSnapshot({lines: int}): {entries: [{seq: int, line: String,
///   stream: "stdout"|"stderr"|"system"}], throughSeq: int}.
/// Missing native handlers become shellbox_<method>_unimplemented errors;
/// native PlatformException codes propagate unchanged. No simulated success.
class ShellBoxRuntimeBridge extends RuntimeBridge {
  ShellBoxRuntimeBridge({ShellBoxRuntimeService? service, MethodChannel? channel})
    : _service = service ?? ShellBoxRuntimeService(channel: channel),
      _channel = _ShellBoxChannel(channel ?? const MethodChannel('dsh/shellbox')),
      super(methods: _ShellBoxChannel(channel ?? const MethodChannel('dsh/shellbox')));

  final ShellBoxRuntimeService _service;
  final MethodChannel _channel;
  Stream<RuntimeEvent>? _statusEvents;

  static RuntimeStatus _status(Map<String, dynamic> raw) {
    final error = raw['error'];
    return RuntimeStatus.fromMap({
      ...raw,
      // RuntimePhase.parse maps the legacy 'unimplemented' phase to error.
      'error': error is Map ? '${error['code']}: ${error['message']}' : error,
    });
  }

  /// One second balances visible lifecycle updates with idle channel traffic.
  /// Polls are serialized, shared by listeners, and stop when unsubscribed.
  @override
  Stream<RuntimeEvent> get events => _statusEvents ??= _createEvents();

  Stream<RuntimeEvent> _createEvents() {
    late StreamController<RuntimeEvent> controller;
    Timer? timer;
    var generation = 0;
    String? previous;

    Future<void> poll(int current) async {
      try {
        final raw = await _service.statusMap();
        if (current != generation) return;
        final status = Map<String, dynamic>.of(raw)..remove('notices');
        final signature = jsonEncode(status);
        if (signature != previous) {
          controller.add(RuntimeStatusEvent(_status(status)));
          previous = signature;
        }
        for (final notice in (raw['notices'] as List? ?? const [])) {
          if (notice is String && notice.isNotEmpty) controller.add(RuntimeNoticeEvent(notice));
        }
      } catch (error, stack) {
        if (current == generation) controller.addError(error, stack);
      } finally {
        if (current == generation) {
          timer = Timer(const Duration(seconds: 1), () => poll(current));
        }
      }
    }

    controller = StreamController<RuntimeEvent>.broadcast(
      onListen: () {
        previous = null;
        unawaited(poll(++generation));
      },
      onCancel: () {
        // Retire any in-flight reply so it cannot publish or schedule another poll.
        generation++;
        timer?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<RuntimeStatus> status() async => _status(await _service.statusMap());

  @override
  Future<void> start({
    Map<String, String> env = const {},
    bool phoneStorage = false,
    EngineMode? mode,
    bool visualReplies = true,
  }) => _channel.invokeMethod<void>('start', {
    'env': env,
    'phoneStorage': phoneStorage,
    'mode': mode?.name,
    'visualReplies': visualReplies,
  });

  @override
  Future<void> stop() => _service.stop();

  // The base implementations swallow PlatformException; keep iOS errors visible.
  @override
  Future<String?> openVendorSettings(String vendorSwitch) =>
      _channel.invokeMethod<String>('openVendorSettings', {'switch': vendorSwitch});

  @override
  Future<bool?> networkMetered() => _channel.invokeMethod<bool>('networkMetered');

  @override
  Future<void> install({bool dropKept = false}) =>
      _channel.invokeMethod<void>('install', dropKept ? const {'dropKept': true} : null);

  @override
  Future<void> reset({ResetKeep keep = const ResetKeep()}) =>
      _channel.invokeMethod<void>('reset', {'keep': keep.wire});

  @override
  Future<List<String>> logs({int lines = 500}) async =>
      (await _channel.invokeListMethod<String>('logs', {'lines': lines}))!;

  @override
  Future<RuntimeLogSnapshot> logSnapshot({int lines = 300}) async =>
      RuntimeLogSnapshot.fromMap(
        (await _channel.invokeMapMethod<Object?, Object?>('logSnapshot', {'lines': lines}))!,
      );
}

/// Routes portable inherited methods without ever touching dsh/runtime.
class _ShellBoxChannel extends MethodChannel {
  const _ShellBoxChannel(this.delegate) : super('dsh/shellbox');
  final MethodChannel delegate;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    switch (method) {
      // Android PRoot execution alternatives do not exist in ShellBox.
      case 'setDirectEngine':
      case 'setTawcEngine':
      // Android shared-storage permissions and /sdcard mounting are unavailable.
      case 'storageStatus':
      case 'requestStorage':
      case 'openAllFilesAccess':
      // Android battery exemptions and OEM settings have no iOS equivalent.
      case 'batteryExempt':
      case 'requestBatteryExempt':
      case 'backgroundSettings':
      case 'openBackgroundSettings':
      case 'openVendorSettings':
        throw PlatformException(code: 'shellbox_${method}_unimplemented');
      // Portable runtime IO, recovery, diagnostics and network observation.
      case 'installManagedSkill':
      case 'cancelManagedSkill':
      case 'lastKnownGood':
      case 'restoreLastKnownGood':
      case 'safePreflight':
      case 'moveAside':
      case 'clearFailure':
      case 'setAutoSafe':
      case 'setWorkspaceRecovery':
      case 'failureLog':
      case 'networkMetered':
      case 'start':
      case 'install':
      case 'reset':
      case 'logs':
      case 'logSnapshot':
        try {
          return await delegate.invokeMethod<T>(method, arguments);
        } on MissingPluginException {
          throw PlatformException(
            code: 'shellbox_${method}_unimplemented',
            message: 'Native ShellBox does not implement $method.',
          );
        }
      default:
        throw PlatformException(code: 'shellbox_${method}_unimplemented');
    }
  }
}
