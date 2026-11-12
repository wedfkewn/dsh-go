import 'dart:io';

/// Boundary for future runtime wiring; does not probe a native channel.
/// Android retains its existing implementation. iOS local execution is pending.
class RuntimePlatformCapabilities {
  const RuntimePlatformCapabilities({
    required this.androidRuntime,
    required this.shellBoxRuntime,
  });

  factory RuntimePlatformCapabilities.current() => RuntimePlatformCapabilities(
    androidRuntime: Platform.isAndroid,
    shellBoxRuntime: false,
  );

  /// PRoot, direct/tawcroot launch and Android runtime/settings channels.
  final bool androidRuntime;

  /// False until ShellBox, Node and the native lifecycle are verified.
  final bool shellBoxRuntime;
}
