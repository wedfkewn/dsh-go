// The Live Activity's art comes from the app (not from the widget's own
// bundle): every sheet the island may crop is staged in the shared folder,
// an unchanged pet is not rewritten, and a build without the App Group leaves
// the widget's emoji fallback in place.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/notify/pet_art_stage.dart';
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

PetPack _diskPack(String id) =>
    PetPack.parse(jsonDecode(File('assets/pets/$id/pack.json').readAsStringSync()) as Map<String, Object?>);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/pet_art');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory group;

  setUp(() {
    group = Directory.systemTemp.createTempSync('pet-art-test');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'artDirectory') return null;
      return group.path;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    group.deleteSync(recursive: true);
  });

  test('stages the pack, its manifest and every sheet it names', () async {
    final stage = PetArtStage(channel: channel);
    final pack = _diskPack('deepy-whale');
    await stage.stage(pack);
    final dir = Directory('${group.path}/${pack.id}');
    expect(File('${dir.path}/pack.json').existsSync(), isTrue);
    for (final anim in pack.animations.values) {
      expect(File('${dir.path}/${anim.sheet}').existsSync(), isTrue, reason: anim.sheet);
    }
    // The widget crops the app's own sheet: same bytes, so same cells.
    final asset = await rootBundle.load('assets/pets/deepy-whale/idle.png');
    expect(File('${dir.path}/idle.png').lengthSync(), asset.lengthInBytes);
    expect(File('${dir.path}/stamp').readAsStringSync(), contains(pack.id));
  });

  test('an unchanged pet is not rewritten; another pet lands beside it', () async {
    final stage = PetArtStage(channel: channel);
    final deepy = _diskPack('deepy-whale');
    await stage.stage(deepy);
    final stamp = File('${group.path}/deepy-whale/stamp');
    final before = stamp.lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await stage.stage(deepy);
    expect(stamp.lastModifiedSync(), before);
    await stage.stage(_diskPack('whale-girl'));
    expect(File('${group.path}/whale-girl/idle.png').existsSync(), isTrue);
  });

  test('without the shared folder nothing is written and nothing throws', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final stage = PetArtStage(channel: channel);
    await stage.stage(_diskPack('deepy-whale'));
    expect(group.listSync(), isEmpty);
    // Not a silent emoji forever: the reason is a code the app can log.
    expect(stage.failure, 'app_group_unavailable');
  });

  test('a working copy clears the failure; a missing plugin names itself', () async {
    final stage = PetArtStage(channel: channel);
    await stage.stage(_diskPack('deepy-whale'));
    expect(stage.failure, isNull);
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final missing = PetArtStage(channel: MethodChannel('test/pet_art_absent'));
    await missing.stage(_diskPack('deepy-whale'));
    expect(missing.failure, 'plugin_unavailable');
  });

  test('every pack names a representative frame its animation really plays', () {
    for (final id in ['deepy-whale', 'whale-girl']) {
      final pack = _diskPack(id);
      for (final anim in pack.animations.values) {
        final cells = {for (final frame in anim.frames) frame.i};
        final still = anim.stillIndex;
        expect(cells, contains(still), reason: '${pack.id}/${anim.name}');
        if (anim.preview case final preview?) {
          expect(preview, still, reason: '${pack.id}/${anim.name} kept its own frame');
        }
      }
      // The one still per state reads from the state's own animation.
      for (final state in [
        'idle',
        'thinking',
        'typing',
        'music',
        'building',
        'conducting',
        'notification',
        'happy',
        'error',
        'compacting',
        'carrying',
        'sleeping',
      ]) {
        expect(pack.animations[state]?.preview, isNotNull, reason: '${pack.id}/$state');
      }
      final attention = pack.states['attention']!.first;
      expect(pack.animations[attention]?.preview, isNotNull);
    }
  });

  test('every state crops a window that keeps the whole body in frame', () {
    for (final id in ['deepy-whale', 'whale-girl']) {
      final pack = _diskPack(id);
      final body = pack.contentBox;
      for (final anim in pack.animations.values) {
        final reason = '${pack.id}/${anim.name}';
        expect(anim.box.width, greaterThan(0), reason: reason);
        expect(anim.box.height, greaterThan(0), reason: reason);
        // The widget frames this window — the body plus whatever props the
        // animation itself adds (keyboard, helmet, thought cloud) — so the pet
        // keeps its size instead of shrinking into a shared canvas.
        final window = anim.box.expandToInclude(body);
        final keepsBody =
            window.left <= body.left &&
            window.top <= body.top &&
            window.right >= body.right &&
            window.bottom >= body.bottom;
        expect(keepsBody, isTrue, reason: '$reason window misses the body');
        // Nothing the sheet can hold is cropped away: stay on the canvas.
        final onCanvas =
            window.left >= 0 &&
            window.top >= 0 &&
            window.right <= pack.canvas.width &&
            window.bottom <= pack.canvas.height;
        expect(onCanvas, isTrue, reason: '$reason window runs off the canvas');
      }
    }
  });
}
