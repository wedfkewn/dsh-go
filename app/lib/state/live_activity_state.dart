// Keeps the live activity (lib/notify/live_activity.dart) fed: the global pet
// state in words, pushed to `dsh/notify` whenever it changes.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notify/live_activity.dart';
import '../notify/pet_art_stage.dart';
import '../notify/pet_live_activity.dart';
import '../notify/pet_live_activity_art.dart';
import '../pets/pet_overlay_actions.dart' show petActionHost;
import '../pets/pet_signals.dart';
import '../pets/pet_state.dart';
import 'notify_state.dart';

export '../notify/live_activity.dart';

/// Titles seen running or focused, so a finished conversation keeps its name.
final _liveTitlesProvider = Provider<Map<PetTarget, String>>((ref) => <PetTarget, String>{});

/// What the live activity shows now; null: nothing. Reads the pet's own
/// signals, so it sees exactly what the pet sees.
final liveActivityProvider = Provider<LiveActivity?>((ref) {
  final signals = ref.watch(petSignalsProvider);
  final titles = ref.watch(_liveTitlesProvider);
  learnLiveTitles(titles, signals.runs, focus: signals.focus);
  final prefs = ref.watch(notifyPrefsProvider);
  return liveActivityOf(
    pet: ref.watch(petStateProvider),
    runs: signals.runs,
    pending: signals.pending,
    focus: signals.focus,
    titles: titles,
    showDone: prefs.done,
    showFailed: prefs.failed,
  );
});

/// What `dsh/notify` is told: off with notifications or the switch, else the
/// activity and the pet whose pictures it uses.
final livePushProvider = Provider<LivePush>((ref) {
  final enabled = ref.watch(notifyPrefsProvider.select((p) => p.enabled && p.live));
  final packId = ref.watch(petStateProvider.select((s) => s.packId == noPetId ? null : s.packId));
  // Watch the loaded pack itself, not only its id: reinstalling a pet can keep
  // the id while replacing every sheet. The identity token makes that a new
  // push even when the activity and pose are unchanged.
  final packToken = packId == null ? null : ref.watch(petPackProvider(packId)).value;
  return LivePush(
    enabled: enabled,
    packId: packId,
    packToken: packToken,
    activity: enabled ? ref.watch(liveActivityProvider) : null,
  );
});

/// Watch it to keep the live activity fed (with the pet overlay's bridge, in
/// both 原生 and 网页 modes). Equal pushes are not sent twice.
final liveActivityBridgeProvider = Provider<void>((ref) {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    ref.watch(iosPetLiveActivityBridgeProvider);
    return;
  }
  ref.listen<LivePush>(livePushProvider, (previous, next) {
    if (previous == next) return;
    unawaited(ref.read(notifyChannelProvider).live(next));
  }, fireImmediately: true);
});

/// What the phone offers; re-read with `ref.invalidate` when the app comes back.
final liveSystemStatusProvider = FutureProvider<LiveSystemStatus>(
  (ref) => ref.watch(notifyChannelProvider).liveStatus(),
);

/// Exposes native failures to consumers without breaking the in-app pet.
final petLiveActivityStatusProvider = NotifierProvider<PetLiveActivityStatus, AsyncValue<String?>>(
  PetLiveActivityStatus.new,
);

class PetLiveActivityStatus extends Notifier<AsyncValue<String?>> {
  @override
  AsyncValue<String?> build() => const AsyncData(null);

  void report(AsyncValue<String?> value) => state = value;
}

final petLiveActivityChannelProvider = Provider<PetLiveActivityChannel>((ref) => PetLiveActivityChannel());

/// The widget extension cannot read Flutter's asset bundle or the app's
/// sandbox. Stage the sheets in the App Group when possible, and also send a
/// small inline still so imported pets survive builds where the App Group is
/// stripped from a sideloaded app.
final petArtStageProvider = Provider<PetArtStage>(
  (ref) => PetArtStage(
    channel: ref.watch(petLiveActivityChannelProvider).channel,
    bundle: ref.watch(petAssetBundleProvider),
  ),
);

final iosPetLiveActivityBridgeProvider = Provider<void>((ref) {
  final bridge = ref.watch(petLiveActivityChannelProvider);
  final bundle = ref.watch(petAssetBundleProvider);
  // The last staging failure said out loud. It is no longer fatal: the inline
  // still is read from the app's own pack before the native update.
  String? stagedFailure;

  Future<PetLiveActivityArt?> inlineArt(LivePush push) async {
    final packId = push.packId;
    if (!push.enabled || packId == null || packId == noPetId) return null;
    try {
      final pack = await ref.read(petPackProvider(packId).future);
      final stage = ref.read(petArtStageProvider);
      await stage.stage(pack);
      if (stage.failure != stagedFailure) {
        stagedFailure = stage.failure;
        debugPrint(
          stage.failure == null
              ? 'pet art: $packId staged for the island'
              : 'pet art: $packId not staged (${stage.failure}); using the inline still',
        );
      }
      return await renderPetLiveActivityArt(pack, push, bundle: bundle);
    } catch (error) {
      // Art is decoration: a broken pack or unavailable staging area must not
      // stop the status update itself.
      debugPrint('pet art: $packId inline still unavailable ($error)');
      return null;
    }
  }

  Future<void> send(LivePush push) async {
    final status = await AsyncValue.guard(() => bridge.push(push, artLoader: () => inlineArt(push)));
    if (ref.mounted) ref.read(petLiveActivityStatusProvider.notifier).report(status);
  }

  bridge.channel.setMethodCallHandler((call) async {
    if (call.method != 'link') return;
    final args = call.arguments;
    final uri = args is Map && args['uri'] is String ? Uri.tryParse(args['uri'] as String) : null;
    if (uri == null || uri.scheme != 'dshgo' || uri.host != 'pet-session') return;
    final host = petActionHost(uri.queryParameters['host']);
    final session = uri.queryParameters['sessionId'];
    if (host == null || session == null || session.isEmpty || session.length > 200) return;
    ref.read(chatAlertsProvider.notifier).open(host, session);
  });
  ref.onDispose(() => bridge.channel.setMethodCallHandler(null));
  unawaited(() async {
    try {
      await bridge.channel.invokeMethod<void>('ready');
    } catch (error, stack) {
      if (ref.mounted) ref.read(petLiveActivityStatusProvider.notifier).report(AsyncError(error, stack));
    }
  }());
  ref.listen<LivePush>(livePushProvider, (previous, next) {
    if (previous != next) unawaited(send(next));
  }, fireImmediately: true);
  // Retry a foreground-only request when the user returns; no timer/retry loop.
  ref.listen<bool>(appForegroundProvider, (previous, next) {
    if (next && previous == false) unawaited(send(ref.read(livePushProvider)));
  });
});
