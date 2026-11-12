import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/notify/live_activity.dart';
import 'package:dsh_app/notify/notify_channel.dart';
import 'package:dsh_app/notify/pet_live_activity.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

LivePush push({LiveKind kind = LiveKind.running, PetStateName mood = PetStateName.thinking}) => LivePush(
  enabled: true,
  activity: LiveActivity(
    kind: kind,
    mood: mood,
    title: 'private title',
    text: 'private text',
    chip: 'Status',
    publicText: 'Public status',
    target: const PetTarget(HostRef.relay('host-id', name: 'private host name'), 'session / 中文'),
    eventId: 'private request',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('six presentation phases preserve reducer projection and privacy', () {
    final cases = [
      (push(mood: PetStateName.idle), 'idle'),
      (push(), 'thinking'),
      (push(mood: PetStateName.working), 'working'),
      (push(mood: PetStateName.juggling), 'working'),
      (push(kind: LiveKind.waiting), 'waitingApproval'),
      (push(kind: LiveKind.done), 'completed'),
      (push(kind: LiveKind.failed), 'error'),
    ];
    for (final (value, phase) in cases) {
      final payload = petLiveActivityPayload(value)!;
      expect(payload['phase'], phase);
      expect(payload.keys.toSet(), {'host', 'sessionId', 'phase', 'label', 'staleLabel'});
      expect(jsonDecode(payload['host'] as String), {'kind': 'relay', 'id': 'host-id'});
      expect(payload['sessionId'], 'session / 中文');
      expect(jsonEncode(payload), isNot(contains('private')));
    }
    expect(petLiveActivityPayload(const LivePush(enabled: false)), isNull);
    expect(petLiveActivityPayload(const LivePush(enabled: true)), isNull);
  });

  const channel = MethodChannel('test/pet_live_activity');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('start, update and end stay ordered while request is pending', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'start') {
        started.complete();
        await release.future;
      }
      return call.method;
    });
    final bridge = PetLiveActivityChannel(channel: channel);
    final first = bridge.push(push());
    await started.future;
    final second = bridge.push(push(mood: PetStateName.working));
    final end = bridge.push(const LivePush(enabled: false));
    expect(calls, ['start']);
    release.complete();
    await Future.wait([first, second, end]);
    expect(calls, ['start', 'update', 'end']);
  });

  test('native failure is observable and does not poison subsequent operations', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') throw PlatformException(code: 'pet_live_activity_disabled');
      return 'ended';
    });
    final bridge = PetLiveActivityChannel(channel: channel);
    await expectLater(bridge.push(push()), throwsA(isA<PlatformException>().having(
      (e) => e.code, 'code', 'pet_live_activity_disabled',
    )));
    expect(await bridge.push(const LivePush(enabled: false)), 'ended');
  });
}
