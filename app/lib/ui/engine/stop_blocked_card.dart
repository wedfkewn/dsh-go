import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';

/// Retains a recovery path while native code owns an unfinished service.
class StopBlockedCard extends ConsumerStatefulWidget {
  const StopBlockedCard({super.key});

  @override
  ConsumerState<StopBlockedCard> createState() => _StopBlockedCardState();
}

class _StopBlockedCardState extends ConsumerState<StopBlockedCard> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await ref.read(localRuntimeProvider.notifier).stop();
    } catch (_) {
      // The native status retains StopBlocked; the card and retry stay visible.
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(localRuntimeProvider.select((state) => state.status));
    final phase = status.phase;
    if (phase != RuntimePhase.stopBlocked && !(phase == RuntimePhase.stopping &&
        (_retrying || (status.error?.startsWith('shellbox_stop_blocked:') ?? false)))) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l10n.shellBoxStopBlocked, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(l10n.shellBoxStopBlockedDetail),
          TextButton(onPressed: _retrying || phase == RuntimePhase.stopping ? null : _retry, child: Text(l10n.shellBoxRetryStop)),
        ]),
      ),
    );
  }
}
