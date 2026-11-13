import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../runtime/shellbox/shellbox_runtime_bridge.dart';
import '../shell/page_frame.dart';

class IosBackgroundPage extends ConsumerStatefulWidget {
  const IosBackgroundPage({super.key});

  @override
  ConsumerState<IosBackgroundPage> createState() => _IosBackgroundPageState();
}

class _IosBackgroundPageState extends ConsumerState<IosBackgroundPage> {
  Map<String, dynamic>? _capabilities;
  Map<String, dynamic>? _snapshot;
  bool _failed = false;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  late final AppLifecycleListener _lifecycle;

  ShellBoxRuntimeBridge get _bridge => ref.read(runtimeBridgeProvider) as ShellBoxRuntimeBridge;

  @override
  void initState() {
    super.initState();
    _subscription = _bridge.backgroundChanges.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final capabilities = await _bridge.getBackgroundCapabilities();
      final snapshot = await _bridge.getBackgroundExecutionState();
      if (mounted) {
        setState(() {
          _capabilities = capabilities;
          _snapshot = snapshot;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _change(Future<void> Function() action) async {
    try {
      await action();
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = switch (_snapshot?['state']) {
      'foreground' => l10n.iosBackgroundForeground,
      'resuming' => l10n.iosBackgroundResuming,
      'backgroundGrace' => l10n.iosBackgroundGraceState,
      'continuedProcessing' => l10n.iosBackgroundContinuedState,
      'expired' => l10n.iosBackgroundExpired,
      'failed' => l10n.iosBackgroundFailed,
      'completed' => l10n.iosBackgroundCompleted,
      'error' => l10n.iosBackgroundError,
      _ => l10n.iosBackgroundUnknown,
    };
    final reason = switch (_capabilities?['reason']) {
      'requires_ios_26' => l10n.iosBackgroundUnsupported,
      'registration_failed' => l10n.iosBackgroundRegistrationFailed,
      _ => l10n.iosBackgroundSystemMayDecline,
    };
    return AppPage.list(
      title: l10n.iosBackgroundTitle,
      children: [
        SwitchListTile.adaptive(
          title: Text(l10n.iosBackgroundEnable),
          subtitle: Text(l10n.iosBackgroundContinued),
          value: _snapshot?['enabled'] == true,
          onChanged: _capabilities?['continuedProcessingOSSupported'] == true
              ? (enabled) => _change(() => _bridge.setBackgroundEnabled(enabled)) : null,
        ),
        ListTile(title: Text(reason)),
        ListTile(title: Text(l10n.iosBackgroundGrace)),
        ListTile(title: Text(l10n.iosBackgroundState), subtitle: Text(state)),
        if (_failed) ListTile(title: Text(l10n.iosBackgroundUnavailable)),
        ListTile(title: Text(l10n.iosBackgroundLimits)),
        TextButton(onPressed: _refresh, child: Text(l10n.iosBackgroundRefresh)),
        if (_snapshot?['authorizationActive'] == true)
          TextButton(
            onPressed: () => _change(_bridge.cancelContinuedProcessing),
            child: Text(l10n.iosBackgroundCancel),
          ),
      ],
    );
  }
}
