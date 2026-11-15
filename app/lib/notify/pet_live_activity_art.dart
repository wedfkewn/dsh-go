import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../pets/pet_pack.dart';
import '../pets/pet_state.dart';
import 'notify_channel.dart';
import 'pet_live_activity.dart';

/// Keep each still small enough for the ActivityKit content payload while
/// retaining enough pixels for the expanded and lock-screen sizes.
const _artSideSteps = [64, 48, 40, 32, 24, 20, 16, 12, 8, 6, 4];
// Swift re-encodes the same fields as JSON before ActivityKit sees them. Leave
// headroom for its key/wrapper bytes instead of sitting on the hard 4 KiB edge.
const _maxContentBytes = 3300;
const _artCacheCapacity = 12;
final _fnvOffset = BigInt.parse('cbf29ce484222325', radix: 16);
final _fnvPrime = BigInt.from(0x100000001b3);
final _u64Mask = (BigInt.one << 64) - BigInt.one;

final LinkedHashMap<String, _CachedArt> _artCache = LinkedHashMap();

/// Renders the exact still the Live Activity is about to show, as a transparent
/// PNG window containing the pet and any action prop. The still travels inside
/// `ContentState`, so the widget extension never has to read the imported pet's
/// App sandbox (or an App Group staging copy).
///
/// Any failure returns null; a missing still must never stop the status update.
Future<PetLiveActivityArt?> renderPetLiveActivityArt(PetPack pack, LivePush push, {required AssetBundle bundle}) async {
  final payload = petLiveActivityPayload(push);
  if (payload == null || payload['packId'] != pack.id) return null;

  final state = PetStateName.fromName(payload['petState'] as String?);
  final tier = (payload['tier'] as num?)?.toInt() ?? 0;
  final anim = _animationFor(pack, state, tier, payload);
  final key = '${pack.id}\u0000${anim.name}';
  if (_artCache.remove(key) case final cached?) {
    if (identical(cached.pack, pack) && _fitsContent(payload, cached.art)) {
      _artCache[key] = cached;
      return cached.art;
    }
  }

  try {
    if (!_safeSheetName(anim.sheet)) return null;
    final sheet = await _sheetBytes(pack, anim.sheet, bundle);
    final window = anim.box.expandToInclude(pack.contentBox);
    final source = anim.sourceRect(anim.stillIndex);
    final bodyRatio = window.height / pack.contentBox.height;
    // Decode the atlas once and emit every size from that image. A Codex v2
    // atlas is 1536 x 2288, so decoding it again for every fallback size would
    // multiply a roughly 14 MB RGBA peak by the size ladder.
    final candidates = await compute(
      _renderPngs,
      _ArtRequest(
        sheet: sheet,
        sourceX: source.left.round(),
        sourceY: source.top.round(),
        sourceWidth: source.width.round(),
        sourceHeight: source.height.round(),
        boxX: anim.box.left,
        boxY: anim.box.top,
        boxWidth: anim.box.width,
        boxHeight: anim.box.height,
        windowX: window.left,
        windowY: window.top,
        windowWidth: window.width,
        windowHeight: window.height,
        maxSides: _artSideSteps,
        pixelArt: pack.pixelArt,
      ),
      debugLabel: 'pet-live-activity-art',
    );
    for (final png in candidates) {
      final art = PetLiveActivityArt(png: png, bodyRatio: bodyRatio, pixelArt: pack.pixelArt);
      if (!_fitsContent(payload, art)) continue;
      _artCache[key] = _CachedArt(pack, art);
      while (_artCache.length > _artCacheCapacity) {
        _artCache.remove(_artCache.keys.first);
      }
      return art;
    }
    return null;
  } catch (error) {
    debugPrint('pet art: ${pack.id}/${anim.name} still unavailable ($error)');
    return null;
  }
}

Future<Uint8List> _sheetBytes(PetPack pack, String sheet, AssetBundle bundle) async {
  if (pack.dir case final dir?) return File('$dir/$sheet').readAsBytes();
  final data = await bundle.load('${PetPack.folder(pack.id)}/$sheet');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

bool _safeSheetName(String name) =>
    name.isNotEmpty && name != '.' && name != '..' && !name.contains('/') && !name.contains(r'\');

PetAnimation _animationFor(PetPack pack, PetStateName state, int tier, Map<String, Object?> payload) {
  if (payload['phase'] == 'completed') {
    final celebration = _celebration(pack, payload['completionSeed'] as String?);
    if (celebration != null) return celebration;
  }
  return pack.animFor(state, tier: tier);
}

/// Mirrors the widget's FNV-1a 64-bit celebration choice, so the inline still
/// and the staged/bundled fallback always agree for the same finished turn.
PetAnimation? _celebration(PetPack pack, String? seed) {
  final bonus = pack.bonus['attention'];
  if (bonus == null || seed == null || bonus.anims.isEmpty) return null;
  final roll = (_hash(seed) % BigInt.from(1000)).toDouble() / 1000;
  if (roll >= bonus.chance) return null;
  final names = [
    for (final name in bonus.anims)
      if (pack.animations.containsKey(name)) name,
  ];
  if (names.isEmpty) return null;
  final index = (_hash('$seed/pick') % BigInt.from(names.length)).toInt();
  return pack.animations[names[index]];
}

BigInt _hash(String text) {
  var value = _fnvOffset;
  for (final byte in utf8.encode(text)) {
    value = ((value ^ BigInt.from(byte)) * _fnvPrime) & _u64Mask;
  }
  return value;
}

/// ActivityKit budgets the whole ContentState, not just the PNG. Reserve room
/// for Swift's JSON encoding differences and shrink the still until the full
/// payload fits; status text must still update when even the smallest does not.
bool _fitsContent(Map<String, Object?> payload, PetLiveActivityArt art) {
  final bytes = utf8
      .encode(
        jsonEncode({
          ...payload,
          'art': base64Encode(art.png),
          'artBodyRatio': art.bodyRatio,
          'artPixelArt': art.pixelArt,
        }),
      )
      .length;
  return bytes <= _maxContentBytes;
}

List<Uint8List> _renderPngs(_ArtRequest request) {
  final decoded = img.decodePng(request.sheet);
  if (decoded == null) throw const FormatException('sheet is not PNG');
  // Palette and low-bit-depth sheets need an explicit RGBA8 expansion before
  // crop/resize/composite; otherwise image may retain packed indices/channels.
  final sheet = decoded.convert(format: img.Format.uint8, numChannels: 4);
  final right = request.sourceX + request.sourceWidth;
  final bottom = request.sourceY + request.sourceHeight;
  if (request.sourceX < 0 ||
      request.sourceY < 0 ||
      request.sourceWidth <= 0 ||
      request.sourceHeight <= 0 ||
      right > sheet.width ||
      bottom > sheet.height ||
      request.windowWidth <= 0 ||
      request.windowHeight <= 0 ||
      request.boxWidth <= 0 ||
      request.boxHeight <= 0) {
    throw const FormatException('still is outside the sheet');
  }

  final cell = img.copyCrop(
    sheet,
    x: request.sourceX,
    y: request.sourceY,
    width: request.sourceWidth,
    height: request.sourceHeight,
  );
  final interpolation = request.pixelArt ? img.Interpolation.nearest : img.Interpolation.linear;
  return [
    for (final maxSide in request.maxSides)
      () {
        final fit = math.min(maxSide / request.windowWidth, maxSide / request.windowHeight);
        final outputWidth = math.max(1, (request.windowWidth * fit).round());
        final outputHeight = math.max(1, (request.windowHeight * fit).round());
        final canvas = img.Image(width: outputWidth, height: outputHeight, numChannels: 4)..clear();
        final placed = img.copyResize(
          cell,
          width: math.max(1, (request.boxWidth * fit).round()),
          height: math.max(1, (request.boxHeight * fit).round()),
          interpolation: interpolation,
        );
        img.compositeImage(
          canvas,
          placed,
          dstX: ((request.boxX - request.windowX) * fit).round(),
          dstY: ((request.boxY - request.windowY) * fit).round(),
        );
        return img.encodePng(canvas, level: 9, singleFrame: true);
      }(),
  ];
}

@immutable
class _ArtRequest {
  const _ArtRequest({
    required this.sheet,
    required this.sourceX,
    required this.sourceY,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.boxX,
    required this.boxY,
    required this.boxWidth,
    required this.boxHeight,
    required this.windowX,
    required this.windowY,
    required this.windowWidth,
    required this.windowHeight,
    required this.maxSides,
    required this.pixelArt,
  });

  final Uint8List sheet;
  final int sourceX;
  final int sourceY;
  final int sourceWidth;
  final int sourceHeight;
  final double boxX;
  final double boxY;
  final double boxWidth;
  final double boxHeight;
  final double windowX;
  final double windowY;
  final double windowWidth;
  final double windowHeight;
  final List<int> maxSides;
  final bool pixelArt;
}

/// Keeps the pack alive for as long as the cached still is reusable. A pack
/// id alone is not an identity: re-imports and tests can produce another pack
/// with the same id and animation name but different bytes.
class _CachedArt {
  const _CachedArt(this.pack, this.art);

  final PetPack pack;
  final PetLiveActivityArt art;
}
