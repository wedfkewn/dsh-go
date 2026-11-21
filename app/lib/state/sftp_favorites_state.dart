// 收藏目录 for 服务器文件: absolute server paths the person jumps back to,
// kept on the phone per host. Which folders someone cares about is a device
// preference, not DSH data, so this never leaves the app and a different host
// (or relay) starts with its own empty list.
//
// Nothing here talks to the server: a favourite whose directory disappeared
// stays listed and only fails when opened, which is what the person needs to
// see instead of it silently vanishing.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hosts_state.dart';

class SftpFavoritesState {
  const SftpFavoritesState({this.paths = const [], this.loaded = false});

  final List<String> paths;
  final bool loaded;

  SftpFavoritesState copyWith({List<String>? paths, bool? loaded}) =>
      SftpFavoritesState(paths: paths ?? this.paths, loaded: loaded ?? this.loaded);
}

class SftpFavoritesController extends Notifier<SftpFavoritesState> {
  SftpFavoritesController(this.host);

  final HostRef host;

  /// One key per host: a relay id and an SSH id must not share favourites.
  static String keyFor(HostRef host) => 'sftp_favorites_${host.kind.name}_${host.id}';

  late Future<void> _loaded;

  @override
  SftpFavoritesState build() {
    _loaded = _load();
    return const SftpFavoritesState();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(keyFor(host));
      if (!ref.mounted) return;
      state = SftpFavoritesState(paths: _decode(raw), loaded: true);
    } catch (_) {
      // No preference store: no favourites, for this run.
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  static List<String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is String && item.startsWith('/')) item,
      ];
    } on FormatException {
      return const [];
    }
  }

  bool contains(String path) => state.paths.contains(path);

  Future<void> toggle(String path) => contains(path) ? remove(path) : add(path);

  Future<void> add(String path) async {
    if (!path.startsWith('/') || contains(path)) return;
    await _save([...state.paths, path]);
  }

  Future<void> remove(String path) async {
    if (!contains(path)) return;
    await _save([
      for (final item in state.paths)
        if (item != path) item,
    ]);
  }

  Future<void> _save(List<String> paths) async {
    await _loaded;
    if (!ref.mounted) return;
    state = SftpFavoritesState(paths: paths, loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyFor(host), jsonEncode(paths));
    } catch (_) {
      // Kept for this run only.
    }
  }
}

final sftpFavoritesProvider = NotifierProvider.autoDispose.family<SftpFavoritesController, SftpFavoritesState, HostRef>(
  SftpFavoritesController.new,
);
