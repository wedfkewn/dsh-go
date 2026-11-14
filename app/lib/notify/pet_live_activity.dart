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
      // One target for the whole selection: choosing another pet updates this
      // activity instead of ending it and asking system for a new one.
      'sessionId': 'local-pet',
      'packId': packId,
      'phase': 'idle',
      'petState': 'idle',
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
  // Keep the app's exact running animation (juggling/sweeping/carrying), not
  // just the six Live Activity phases; the widget uses it when its phase and
  // pack contain that state.
  final petState = switch (activity.kind) {
    LiveKind.waiting => 'notification',
    LiveKind.done => 'attention',
    LiveKind.failed => 'error',
    LiveKind.running => switch (activity.mood) {
      PetStateName.thinking => 'thinking',
      PetStateName.working ||
      PetStateName.juggling ||
      PetStateName.sweeping ||
      PetStateName.carrying => activity.mood.name,
      _ => 'idle',
    },
  };
  // The expanded card's one line under the headline. [publicText] is the
  // reducer's already-redacted public sentence; [text] may carry conversation
  // detail and must not cross the native boundary.
  final detail = activity.publicText;
  final tier = phase == 'working' && activity.tier > 0 ? activity.tier : null;
  return {
    // Exclude the optional host display name from external presentation data.
    'host': jsonEncode({'kind': target.host.kind.name, 'id': target.host.id}),
    'sessionId': target.sessionId,
    'packId': ?packId,
    if (packId != null) 'petState': petState,
    if (packId != null && tier != null) 'tier': tier,
    'phase': phase,
    'detail': detail,
    if (activity.since case final since?) 'since': since.millisecondsSinceEpoch,
    if (activity.kind == LiveKind.done) 'completionSeed': completionSeed(activity),
    'label': phase == 'idle' ? appL10n.companionStatusIdle : activity.chip,
    'staleLabel': appL10n.mediaConfigKeyUnknown,
  };
}

/// A short, stable stand-in for the finished turn ([LiveActivity.eventId]): the
/// island picks its celebration (happy, or a pack's extra) from it, and the same
/// turn always redraws the same pose. The event id itself never leaves the app.
String completionSeed(LiveActivity activity) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(activity.eventId ?? activity.title)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

class PetLiveActivityChannel {
  PetLiveActivityChannel({MethodChannel? channel}) : channel = channel ?? const MethodChannel('dsh/pet_live_activity');

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
          payload == null
              ? 'end'
              : key == _target
              ? 'update'
              : 'start',
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
