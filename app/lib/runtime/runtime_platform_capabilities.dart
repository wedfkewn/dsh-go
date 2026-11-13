import 'dart:io';

/// Boundary for future runtime wiring; does not probe a native channel.
/// Android retains its existing implementation. iOS local execution is pending.
class RuntimePlatformCapabilities {
  const RuntimePlatformCapabilities({
    required this.androidRuntime,
    required this.shellBoxRuntime,
    this.nativeNodeRuntime = false,
  });

  factory RuntimePlatformCapabilities.current() => RuntimePlatformCapabilities(
    androidRuntime: Platform.isAndroid,
    shellBoxRuntime: false,
    nativeNodeRuntime: false,
  );

  /// PRoot, direct/tawcroot launch and Android runtime/settings channels.
  final bool androidRuntime;

  /// False until ShellBox, Node and the native lifecycle are verified.
  final bool shellBoxRuntime;

  /// Disabled until signed NodeMobile binaries and authenticated DSH readiness
  /// have passed device acceptance tests. Never infer from Platform.isIOS.
  final bool nativeNodeRuntime;
}
