// The chosen pet's cells, copied where the widget extension can read them.
// An extension gets neither the app's asset bundle nor its sandbox, so the
// Live Activity would have only an emoji; instead the app writes the pack
// (`pack.json` plus the sheets it names, verbatim) into the App Group folder
// `PetArtStore` names (PetActivityAttributes.swift), and the widget crops the
// very cells the app draws. `stamp` lets the widget tell a new pack from a
// re-imported one.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../pets/pet_pack.dart';

/// Writes [PetPack] art to `<App Group>/pet-art/<pack id>/`.
class PetArtStage {
  PetArtStage({required this.channel, AssetBundle? bundle}) : bundle = bundle ?? rootBundle;

  final MethodChannel channel;
  final AssetBundle bundle;

  /// The shared folder; null when this build has no App Group (the island
  /// keeps its emoji).
  Future<String?>? _base;

  /// Why the last copy could not be made, as a fixed code (`app_group_unavailable`,
  /// `plugin_unavailable`, `asset_missing`, `write_failed`); null after a copy
  /// that worked. Codes only: no paths, no pet or conversation names.
  String? get failure => _failure;
  String? _failure;

  /// pack id → the stamp last written, so an unchanged pet writes nothing.
  final Map<String, String> _written = {};

  Future<void> stage(PetPack pack) async {
    final base = await (_base ??= _directory());
    if (base == null) return;
    final List<_ArtFile> files;
    try {
      files = await _files(pack);
    } catch (error) {
      _failure = 'asset_missing';
      debugPrint('pet art: ${pack.id} sheets unreadable ($error)');
      return;
    }
    final stamp = _stamp(pack, files);
    if (_written[pack.id] == stamp) {
      _failure = null;
      return;
    }
    final directory = Directory('$base/${pack.id}');
    final stampFile = File('${directory.path}/stamp');
    if (stampFile.existsSync() && await stampFile.readAsString() == stamp) {
      _written[pack.id] = stamp;
      _failure = null;
      return;
    }
    try {
      await directory.create(recursive: true);
      for (final file in files) {
        await File('${directory.path}/${file.name}').writeAsBytes(file.bytes);
      }
      // Written last: a stamp without its files never claims to be complete.
      await stampFile.writeAsString(stamp);
    } catch (error) {
      _failure = 'write_failed';
      debugPrint('pet art: ${pack.id} copy failed ($error)');
      return;
    }
    _written[pack.id] = stamp;
    _failure = null;
  }

  Future<String?> _directory() async {
    try {
      final path = await channel.invokeMethod<String>('artDirectory');
      if (path == null || path.isEmpty) {
        _failure = 'app_group_unavailable';
        return null;
      }
      return path;
    } on MissingPluginException {
      _failure = 'plugin_unavailable';
      return null;
    } on PlatformException {
      _failure = 'app_group_unavailable';
      return null;
    }
  }

  /// `pack.json` and one copy of every sheet the pack names.
  Future<List<_ArtFile>> _files(PetPack pack) async {
    final names = {'pack.json', for (final anim in pack.animations.values) anim.sheet};
    return [for (final name in names) _ArtFile(name, await _bytes(pack, name))];
  }

  Future<Uint8List> _bytes(PetPack pack, String name) async {
    // A brought pet's files are already files; the built-in ones are assets.
    if (pack.dir case final dir?) return File('$dir/$name').readAsBytes();
    final data = await bundle.load('${PetPack.folder(pack.id)}/$name');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// The pack's identity and the size of every file it wrote: a re-import
  /// loads a new [PetPack], so the widget is told to read the pack again.
  String _stamp(PetPack pack, List<_ArtFile> files) =>
      [pack.id, identityHashCode(pack), for (final file in files) '${file.name}=${file.bytes.length}'].join('\u0000');
}

class _ArtFile {
  const _ArtFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}
