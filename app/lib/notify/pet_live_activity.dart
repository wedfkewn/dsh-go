import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../pets/pet_state.dart';
import 'live_activity.dart';
import 'notify_channel.dart';

/// Presentation-only adaptation of the existing LivePush/reducer contract.
/// No titles, approval details, prompts or credentials go onto the lock screen.
Map<String, Object?>? petLiveActivityPayload(LivePush push) {
  if (!push.enabled) return null;
  final packId = push.packId == noPetId ? null : push.packId;
  final activity = push.activity;
  final target = activity?.target;
  if (activity == null || target == null) {
    if (packId == null) return null;
    // iOS-only fallback: keep the selected pet visible between conversations.
    // This opaque target cannot be mistaken for a real chat host.
    return {
      'host': 'local-pet',
      'sessionId': packId,
      'packId': packId,
      'phase': 'idle',
      'label': appL10n.companionStatusIdle,
      'staleLabel': appL10n.mediaConfigKeyUnknown,
    };
  }
  final phase = switch (activity.kind) {
    LiveKind.waiting => 'waitingApproval',
    LiveKind.done => 'completed',
    LiveKind.failed => 'error',
    LiveKind.running => switch (activity.mood) {
      PetStateName.thinking => 'thinking',
      PetStateName.working || PetStateName.juggling || PetStateName.sweeping || PetStateName.carrying => 'working',
      _ => 'idle',
    },
  };
  return {
    // Exclude the optional host display name from external presentation data.
    'host': jsonEncode({'kind': target.host.kind.name, 'id': target.host.id}),
    'sessionId': target.sessionId,
    'packId': ?packId,
    'phase': phase,
    'label': phase == 'idle' ? appL10n.companionStatusIdle : activity.chip,
    'staleLabel': appL10n.mediaConfigKeyUnknown,
  };
}

class PetLiveActivityChannel {
  PetLiveActivityChannel({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('dsh/pet_live_activity');

  final MethodChannel channel;
  Future<void> _tail = Future<void>.value();
  String? _target;

  /// Serialize mutations so a slow request cannot overtake a newer end/update.
  Future<String?> push(LivePush push) {
    final completer = Completer<String?>();
    _tail = _tail.then((_) async {
      try {
        final payload = petLiveActivityPayload(push);
        final key = payload == null ? null : '${payload['host']}\u0000${payload['sessionId']}';
        final result = await channel.invokeMethod<String>(
          payload == null ? 'end' : key == _target ? 'update' : 'start',
          payload,
        );
        _target = key;
        completer.complete(result);
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }
}
