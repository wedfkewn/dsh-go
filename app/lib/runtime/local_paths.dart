// Where the on-device engine's files are, as the engine itself sees them: what
// the app hands it (a new session's cwd) and reads back from it (tool paths).
//
// Android's engine runs in a Linux guest, so these are the guest's fixed paths
// and the guest root is `filesDir/runtime/rootfs`. HarmonyOS has no guest: the
// engine runs in the app's own process and sees real sandbox paths, which only
// the OS knows. It keeps the same layout under a root the native side reports,
// so a guest path still joins onto the root the same way on both. iOS is the
// same as HarmonyOS except that the native Node runtime has its own layout
// (`NativeNode/home`) and reports home and workspace outright.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LocalPaths {
  LocalPaths._();

  static String? _root;
  static String? _deviceHome;
  static String? _deviceWorkspace;

  /// The directory that stands for `/` on HarmonyOS. Null on Android, where
  /// the guest root moves with the install ([GuestFs.local] looks it up), and
  /// null on iOS, which has no guest at all.
  static String? get root => _root;

  /// Whether the engine sees real paths and has no guest around it.
  static bool get noGuest => _root != null || _deviceWorkspace != null;

  /// Home of the engine's user.
  static String get home => _deviceHome ?? '${_root ?? ''}/root';

  /// Default working directory for sessions created on the phone.
  static String get workspace => _deviceWorkspace ?? '$home/workspace';

  /// Asks for the paths before the first frame where there's no guest
  /// (HarmonyOS, iOS). Without an answer they stay Android's, and the engine
  /// refuses them: that shows up as a failed session rather than a wrong folder.
  /// iOS asks its in-process Node runtime for the real sandbox home/workspace;
  /// HarmonyOS asks for the guest root. Android asks nobody.
  static Future<void> load({
    bool? ohos,
    bool? ios,
    MethodChannel channel = const MethodChannel('dsh/runtime'),
    MethodChannel nativeNode = const MethodChannel('dsh/native_node'),
  }) async {
    final onIos = ios ?? Platform.isIOS;
    final onOhos = ohos ?? (Platform.operatingSystem == 'ohos');
    if (!(onIos || onOhos)) return;
    if (onIos) {
      try {
        final paths = await nativeNode.invokeMapMethod<String, Object?>('paths');
        final home = _absolute(paths?['home']);
        final workspace = _absolute(paths?['workspace']);
        if (home != null && workspace != null && workspace.startsWith('$home/')) {
          _deviceHome = home;
          _deviceWorkspace = workspace;
          return;
        }
      } on PlatformException {
        // A build with a different local runtime falls through to dsh/runtime.
      } on MissingPluginException {
        // No native Node side.
      }
    }
    try {
      final root = await channel.invokeMethod<String>('guestRoot');
      final value = _absolute(root);
      if (value != null) _root = value;
    } on PlatformException {
      // The native side couldn't say.
    } on MissingPluginException {
      // No native side.
    }
  }

  static String? _absolute(Object? value) {
    if (value is! String || !value.startsWith('/') || value.contains('\x00')) return null;
    final parts = value.substring(1).split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) return null;
    return value;
  }

  @visibleForTesting
  static set debugRoot(String? root) {
    _root = root;
    _deviceHome = null;
    _deviceWorkspace = null;
  }
}
