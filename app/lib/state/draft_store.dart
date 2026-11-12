import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'attachments.dart';
import 'hosts_state.dart';

/// What is in the composer of one conversation and not sent yet.
class ChatDraft {
  const ChatDraft({this.text = '', this.attachments = const [], required this.updatedAt});

  final String text;
  final List<DraftAttachment> attachments;
  final DateTime updatedAt;
}

class DraftState {
  const DraftState({this.drafts = const {}, this.loaded = false});

  /// By session id; `new` is the new-chat screen.
  final Map<String, ChatDraft> drafts;

  /// The saved texts are in (they arrive a moment after launch).
  final bool loaded;
}

/// Composer drafts per conversation. The text of the latest 30 survives a
/// restart; attachments only live as long as the app.
class DraftStore extends Notifier<DraftState> {
  static const preferenceKey = 'chat_drafts_by_host_v2';
  static const limit = 30;

  final _all = <String, ChatDraft>{};
  String _key(HostRef host, String session) => '${host.kind.name}:${host.id}::$session';
  void _publish() {
    final prefix = '${ref.read(activeHostProvider).kind.name}:${ref.read(activeHostProvider).id}::';
    state = DraftState(drafts: Map.unmodifiable({
      for (final entry in _all.entries)
        if (entry.key.startsWith(prefix)) entry.key.substring(prefix.length): entry.value,
    }), loaded: state.loaded);
  }

  Timer? _write;
  final _forgotten = <String>{};
  late Future<void> _restored;

  @override
  DraftState build() {
    ref.onDispose(() => _write?.cancel());
    ref.listen(activeHostProvider, (_, _) => _publish());
    _restored = _restore();
    return const DraftState();
  }

  Future<void> _restore() async {
    final restored = <String, ChatDraft>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(preferenceKey);
      if (raw != null) {
        for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries) {
          restored[key as String] = ChatDraft(
            text: value['t'] as String,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(value['at'] as int),
          );
        }
      }
    } catch (_) {
      // No preferences backend (tests) or an unreadable value: start empty.
    }
    if (!ref.mounted) return;
    // Anything typed before the load finished wins.
    _all.addAll({...restored, ..._all}..removeWhere((key, _) => _forgotten.contains(key)));
    state = const DraftState(loaded: true);
    _publish();
  }

  /// Empty text and no attachments drops the slot.
  void save(String key, String text, List<DraftAttachment> attachments, {HostRef? host}) {
    final scoped = _key(host ?? ref.read(activeHostProvider), key);
    if (_forgotten.contains(scoped)) return;
    final current = _all[scoped];
    if ((current?.text ?? '') == text && listEquals(current?.attachments ?? const [], attachments)) return;
    if (text.isEmpty && attachments.isEmpty) {
      _all.remove(scoped);
    } else {
      _all[scoped] = ChatDraft(text: text, attachments: List.unmodifiable(attachments), updatedAt: DateTime.now());
    }
    final prefix = scoped.substring(0, scoped.lastIndexOf('::') + 2);
    final entries = _all.entries.where((e) => e.key.startsWith(prefix)).toList()
      ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    for (final entry in entries.skip(limit)) { _all.remove(entry.key); }
    _publish();
    _write?.cancel();
    _write = Timer(const Duration(milliseconds: 400), () => unawaited(flush()));
  }

  void clear(String key) => save(key, '', const []);

  void forget(String key) {
    final scoped = _key(ref.read(activeHostProvider), key);
    _forgotten.add(scoped);
    _all.remove(scoped);
    _publish();
    _write?.cancel();
    _write = Timer(const Duration(milliseconds: 400), () => unawaited(flush()));
  }

  /// Writes the texts now (also done 400 ms after the last change).
  Future<void> flush() async {
    _write?.cancel();
    _write = null;
    // Writing before the saved drafts are in would drop them.
    await _restored;
    if (!ref.mounted) return;
    final json = jsonEncode({
      for (final MapEntry(:key, :value) in _all.entries)
        if (value.text.isNotEmpty) key: {'t': value.text, 'at': value.updatedAt.millisecondsSinceEpoch},
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(preferenceKey, json);
    } catch (_) {}
  }
}

final draftStoreProvider = NotifierProvider<DraftStore, DraftState>(DraftStore.new);
