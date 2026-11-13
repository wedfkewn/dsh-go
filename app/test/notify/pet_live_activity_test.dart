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

  test('selected pet idle fallback respects selection and enabled switch', () {
    const idle = LivePush(enabled: true, packId: 'deepy-whale');
    final payload = petLiveActivityPayload(idle)!;
    expect(payload['host'], 'local-pet');
    expect(payload['sessionId'], 'deepy-whale');
    expect(payload['packId'], 'deepy-whale');
    expect(payload['phase'], 'idle');
    expect(petLiveActivityPayload(idle), payload);
    expect(petLiveActivityPayload(const LivePush(enabled: true, packId: noPetId)), isNull);
    expect(petLiveActivityPayload(const LivePush(enabled: false, packId: 'deepy-whale')), isNull);
    final active = petLiveActivityPayload(LivePush(enabled: true, packId: 'deepy-whale', activity: push().activity))!;
    expect(active['phase'], 'thinking');
    expect(active['sessionId'], 'session / 中文');
    expect(active['packId'], 'deepy-whale');
    expect(active['label'], 'Status');
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

  test('selection, session takeover, idle return, switch and removal', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method;
    });
    final bridge = PetLiveActivityChannel(channel: channel);
    const idle = LivePush(enabled: true, packId: 'deepy-whale');
    await bridge.push(idle);
    await bridge.push(idle);
    await bridge.push(LivePush(enabled: true, packId: 'deepy-whale', activity: push().activity));
    await bridge.push(idle);
    await bridge.push(const LivePush(enabled: true, packId: 'whale-girl'));
    await bridge.push(const LivePush(enabled: true, packId: noPetId));
    expect(calls.map((c) => c.method), ['start', 'update', 'start', 'start', 'start', 'end']);
    expect((calls[3].arguments as Map)['phase'], 'idle');
    expect((calls[4].arguments as Map)['packId'], 'whale-girl');
  });

  test('native failure is observable and does not poison subsequent operations', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') throw PlatformException(code: 'pet_live_activity_disabled');
      return 'ended';
    });
    final bridge = PetLiveActivityChannel(channel: channel);
    await expectLater(
      bridge.push(push()),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'pet_live_activity_disabled')),
    );
    expect(await bridge.push(const LivePush(enabled: false)), 'ended');
  });
}
