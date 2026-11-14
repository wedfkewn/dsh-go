import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../security/app_lock.dart';

class AppLockTile extends ConsumerWidget {
  const AppLockTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(appLockProvider);
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) => SwitchListTile(
        title: Text(context.l10n.iosAppLock),
        subtitle: Text(lock.error ?? context.l10n.iosAppLockDetail),
        value: lock.enabled,
        onChanged: lock.ready && !lock.busy ? (value) => unawaited(lock.authenticate(enable: value)) : null,
      ),
    );
  }
}

/// Above Navigator so a settings route, sheet or deep link cannot bypass it.
/// Offstage preserves the route tree while hiding content and semantics.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> with WidgetsBindingObserver {
  late final AppLock _lock;
  bool _inactive = false;

  @override
  void initState() {
    super.initState();
    _lock = ref.read(appLockProvider);
    unawaited(_lock.load());
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Inactive also covers the system auth prompt: cover content for app-switcher
    // snapshots, but do not relock the successful prompt on its way back.
    setState(() => _inactive = state != AppLifecycleState.resumed);
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) _lock.lock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _lock,
    builder: (context, _) {
      final covered = !_lock.ready || _lock.locked || (_lock.enabled && _inactive);
      return Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: covered,
            child: Offstage(offstage: covered, child: TickerMode(enabled: !covered, child: widget.child)),
          ),
          if (covered)
            Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(context.l10n.iosAppLock, style: Theme.of(context).textTheme.headlineSmall),
                        if (_lock.error case final message?) Text(message),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _lock.busy ? null : () => unawaited(
                            _lock.ready ? _lock.authenticate() : _lock.load(),
                          ),
                          child: Text(context.l10n.iosUnlock),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
