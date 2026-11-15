import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dsh_app/notify/live_activity.dart';
import 'package:dsh_app/notify/notify_channel.dart';
import 'package:dsh_app/notify/pet_live_activity.dart';
import 'package:dsh_app/notify/pet_live_activity_art.dart';
import 'package:dsh_app/pets/codex_pet_converter.dart';
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

LivePush _push(String packId) => LivePush(
  enabled: true,
  packId: packId,
  activity: LiveActivity(
    kind: LiveKind.running,
    mood: PetStateName.working,
    title: 'private title',
    text: 'private text',
    chip: 'Status',
    publicText: 'Public status',
    target: const PetTarget(HostRef.relay('host-id'), 'session'),
    tier: 2,
  ),
);

Future<Map<String, Object?>> _sourceJson() async =>
    jsonDecode(File('assets/pets/deepy-whale/pack.json').readAsStringSync()) as Map<String, Object?>;

Future<PetPack> _assetPack(String id) async => PetPack.parse(await _sourceJson());

Future<PetPack> _filePack(String id, Directory dir) async {
  final json = await _sourceJson();
  json['id'] = id;
  final sheets = {for (final animation in (json['animations'] as Map).values.cast<Map>()) animation['sheet'] as String};
  for (final sheet in sheets) {
    await File('assets/pets/deepy-whale/$sheet').copy('${dir.path}/$sheet');
  }
  return PetPack.parse(json, dir: dir.path);
}

Uint8List _codexAtlas() {
  final image = img.Image(width: 1536, height: 2288, numChannels: 4);
  const counts = [6, 8, 8, 4, 5, 8, 6, 6, 6, 8, 8];
  for (var row = 0; row < 11; row++) {
    for (var col = 0; col < counts[row]; col++) {
      img.fillRect(
        image,
        x1: col * 192 + 40,
        y1: row * 208 + 40,
        x2: col * 192 + 151,
        y2: row * 208 + 167,
        color: img.ColorRgba8(32 + (row * 19) % 180, 64 + (col * 23) % 160, 160, 255),
      );
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

PetPack _codexPack(Directory dir) {
  final archive = Archive()..add(ArchiveFile.bytes('pet.json', utf8.encode(jsonEncode(_codexMetadata))));
  archive.add(ArchiveFile.bytes('spritesheet.png', _codexAtlas()));
  final converted = CodexPetConverter.convertArchive(Uint8List.fromList(ZipEncoder().encode(archive)));
  for (final entry in converted.validated.sheets.entries) {
    File('${dir.path}/${entry.key}').writeAsBytesSync(entry.value);
  }
  return PetPack.parse(converted.validated.json, dir: dir.path);
}

const _codexMetadata = {
  'id': 'imported-codex',
  'displayName': 'Imported Codex',
  'spritesheetPath': 'spritesheet.png',
  'spriteVersionNumber': 2,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the complete inline state stays within the ActivityKit budget', () async {
    final push = _push('deepy-whale');
    final payload = petLiveActivityPayload(push)!;
    final art = await renderPetLiveActivityArt(await _assetPack('deepy-whale'), push, bundle: rootBundle);

    expect(art, isNotNull);
    final size = utf8
        .encode(
          jsonEncode({
            ...payload,
            'art': base64Encode(art!.png),
            'artBodyRatio': art.bodyRatio,
            'artPixelArt': art.pixelArt,
          }),
        )
        .length;
    expect(size, lessThanOrEqualTo(3300));
  });

  test('built-in pet renders a bounded transparent still', () async {
    final art = await renderPetLiveActivityArt(
      await _assetPack('deepy-whale'),
      _push('deepy-whale'),
      bundle: rootBundle,
    );

    expect(art, isNotNull);
    final image = img.decodePng(art!.png);
    expect(image, isNotNull);
    expect(image!.width, lessThanOrEqualTo(64));
    expect(image.height, lessThanOrEqualTo(64));
    expect(art.png.length, lessThan(64 * 1024));
    expect(art.bodyRatio, greaterThanOrEqualTo(1));
    expect(image.any((pixel) => pixel.a == 0), isTrue);
    expect(image.any((pixel) => pixel.a > 0), isTrue);
  });

  test('an imported pet renders from its app-sandbox folder without App Group', () async {
    final dir = await Directory.systemTemp.createTemp('dsh-pet-art-');
    addTearDown(() => dir.delete(recursive: true));
    final art = await renderPetLiveActivityArt(
      await _filePack('imported-whale', dir),
      _push('imported-whale'),
      bundle: rootBundle,
    );

    expect(art, isNotNull);
    final image = img.decodePng(art!.png);
    expect(image, isNotNull);
    expect(image!.width, lessThanOrEqualTo(64));
    expect(image.height, lessThanOrEqualTo(64));
  });

  test('a missing or corrupt sheet degrades to no inline art', () async {
    final missing = await Directory.systemTemp.createTemp('dsh-pet-art-missing-');
    final corrupt = await Directory.systemTemp.createTemp('dsh-pet-art-corrupt-');
    addTearDown(() => missing.delete(recursive: true));
    addTearDown(() => corrupt.delete(recursive: true));
    final corruptPack = await _filePack('corrupt-whale', corrupt);
    final json = await _sourceJson();
    // `_push` is a tier-2 working turn, so `music` (not `idle`) is the
    // animation the inline still reads.
    final music = (json['animations'] as Map)['music'] as Map;
    await File('${corrupt.path}/${music['sheet']}').writeAsString('not a png');

    expect(
      await renderPetLiveActivityArt(
        PetPack.parse(json..['id'] = 'missing-whale', dir: missing.path),
        _push('missing-whale'),
        bundle: rootBundle,
      ),
      isNull,
    );
    expect(await renderPetLiveActivityArt(corruptPack, _push('corrupt-whale'), bundle: rootBundle), isNull);
  });
  test('a full-size Codex v2 imported atlas fits the inline ActivityKit budget', () async {
    final dir = await Directory.systemTemp.createTemp('dsh-codex-art-');
    addTearDown(() => dir.delete(recursive: true));
    final push = _push('imported-codex');
    final art = await renderPetLiveActivityArt(_codexPack(dir), push, bundle: rootBundle);
    final payload = petLiveActivityPayload(push)!;

    expect(art, isNotNull);
    final image = img.decodePng(art!.png);
    expect(image, isNotNull);
    expect(image!.any((pixel) => pixel.a > 0), isTrue);
    expect(image.any((pixel) => pixel.a == 0), isTrue);
    final size = utf8
        .encode(
          jsonEncode({
            ...payload,
            'art': base64Encode(art.png),
            'artBodyRatio': art.bodyRatio,
            'artPixelArt': art.pixelArt,
          }),
        )
        .length;
    expect(size, lessThanOrEqualTo(3300));
  });
}
