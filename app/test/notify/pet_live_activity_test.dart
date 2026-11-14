import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/notify/live_activity.dart';
import 'package:dsh_app/notify/notify_channel.dart';
import 'package:dsh_app/notify/pet_live_activity.dart';
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

LivePush push({
  LiveKind kind = LiveKind.running,
  PetStateName mood = PetStateName.thinking,
  String? packId,
  int tier = 0,
  String? eventId = 'private request',
}) => LivePush(
  enabled: true,
  packId: packId,
  activity: LiveActivity(
    kind: kind,
    mood: mood,
    title: 'private title',
    text: 'private text',
    chip: 'Status',
    publicText: 'Public status',
    target: const PetTarget(HostRef.relay('host-id', name: 'private host name'), 'session / 中文'),
    eventId: eventId,
    tier: tier,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('six presentation phases preserve reducer projection and privacy', () {
    final cases = [
      (push(packId: 'deepy-whale', mood: PetStateName.idle), 'idle', 'idle'),
      (push(packId: 'deepy-whale'), 'thinking', 'thinking'),
      (push(packId: 'deepy-whale', mood: PetStateName.working), 'working', 'working'),
      (push(packId: 'deepy-whale', mood: PetStateName.juggling), 'working', 'juggling'),
      (push(packId: 'deepy-whale', mood: PetStateName.sweeping), 'working', 'sweeping'),
      (push(packId: 'deepy-whale', mood: PetStateName.carrying), 'working', 'carrying'),
      (push(packId: 'deepy-whale', kind: LiveKind.waiting), 'waitingApproval', 'notification'),
      (push(packId: 'deepy-whale', kind: LiveKind.done), 'completed', 'attention'),
      (push(packId: 'deepy-whale', kind: LiveKind.failed), 'error', 'error'),
    ];
    for (final (value, phase, petState) in cases) {
      final payload = petLiveActivityPayload(value)!;
      expect(payload['phase'], phase);
      expect(payload['petState'], petState);
      expect(payload.keys.toSet(), {
        'host',
        'sessionId',
        'packId',
        'phase',
        'petState',
        'detail',
        'label',
        'staleLabel',
        if (value.activity!.tier > 0) 'tier',
        if (value.activity!.kind == LiveKind.done) 'completionSeed',
      });
      expect(jsonDecode(payload['host'] as String), {'kind': 'relay', 'id': 'host-id'});
      expect(payload['sessionId'], 'session / 中文');
      expect(jsonEncode(payload), isNot(contains('private')));
    }
    expect(petLiveActivityPayload(const LivePush(enabled: false)), isNull);
    expect(petLiveActivityPayload(const LivePush(enabled: true)), isNull);
  });

  test('the busy tier reaches the island, so it can play typing, music or building', () {
    for (final (mood, tier, petState) in [
      (PetStateName.working, 1, 'working'),
      (PetStateName.working, 2, 'working'),
      (PetStateName.working, 3, 'working'),
      (PetStateName.juggling, 1, 'juggling'),
      (PetStateName.juggling, 2, 'juggling'),
    ]) {
      final payload = petLiveActivityPayload(push(packId: 'deepy-whale', mood: mood, tier: tier))!;
      expect(payload['phase'], 'working');
      expect(payload['petState'], petState);
      expect(payload['tier'], tier);
    }
    // No tier: the payload keeps the field out entirely, so an older widget and
    // an idle pet read the same shape.
    final untiered = petLiveActivityPayload(push(packId: 'deepy-whale', mood: PetStateName.working))!;
    expect(untiered.containsKey('tier'), isFalse);
    expect(
      petLiveActivityPayload(push(packId: 'deepy-whale', kind: LiveKind.done, tier: 3))!.containsKey('tier'),
      isFalse,
    );
    // The island's own table: the same pack answers the same animations.
    final pack = PetPack.parse(
      jsonDecode(File('assets/pets/deepy-whale/pack.json').readAsStringSync()) as Map<String, Object?>,
    );
    expect(pack.animFor(PetStateName.working, tier: 1).name, 'typing');
    expect(pack.animFor(PetStateName.working, tier: 2).name, 'music');
    expect(pack.animFor(PetStateName.working, tier: 3).name, 'building');
    expect(pack.animFor(PetStateName.juggling, tier: 1).name, 'music');
    expect(pack.animFor(PetStateName.juggling, tier: 2).name, 'conducting');
    expect(pack.animFor(PetStateName.working).name, 'typing');
  });

  test('a request waiting on the person wins over the pose around it', () {
    final waiting = petLiveActivityPayload(
      push(packId: 'deepy-whale', kind: LiveKind.waiting, mood: PetStateName.attention, tier: 3),
    )!;
    expect(waiting['phase'], 'waitingApproval');
    expect(waiting['petState'], 'notification');
    expect(waiting['tier'], isNull);
  });

  test('a finished turn keeps one celebration, chosen from its own turn', () {
    String seedFor(String? eventId) =>
        petLiveActivityPayload(push(packId: 'whale-girl', kind: LiveKind.done, eventId: eventId))!['completionSeed']!
            as String;

    final first = seedFor('event-a');
    expect(first, seedFor('event-a'));
    expect(first, matches(RegExp(r'^[0-9a-f]{8}$')));
    expect(first, isNot(seedFor('event-b')));
    // The opaque id itself never reaches the notification payload.
    expect(first, isNot(contains('event-a')));
    final payload = petLiveActivityPayload(push(packId: 'whale-girl', kind: LiveKind.done))!;
    expect(payload.containsKey('completionSeed'), isTrue);
  });

  test('the run start rides along so the chip can count', () {
    final activity = LiveActivity(
      kind: LiveKind.running,
      mood: PetStateName.working,
      title: 'private title',
      text: 'private text',
      chip: 'Status',
      publicText: 'Public status',
      target: const PetTarget(HostRef.relay('host-id'), 'session'),
      since: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    final payload = petLiveActivityPayload(LivePush(enabled: true, packId: 'deepy-whale', activity: activity))!;
    expect(payload['since'], 1700000000000);
  });

  test('selected pet idle fallback respects selection and enabled switch', () {
    const idle = LivePush(enabled: true, packId: 'deepy-whale');
    final payload = petLiveActivityPayload(idle)!;
    expect(payload['host'], 'local-pet');
    expect(payload['sessionId'], 'local-pet');
    expect(payload['packId'], 'deepy-whale');
    expect(payload['phase'], 'idle');
    expect(payload['petState'], 'idle');
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
    // A new pet is the same activity updated in place: switching one in the
    // app changes the island at once, instead of ending it and asking the
    // system for another (which the system may throttle).
    expect(calls.map((c) => c.method), ['start', 'update', 'start', 'start', 'update', 'end']);
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
