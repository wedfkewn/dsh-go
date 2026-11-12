import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';

/// Enabled only after a successful device authentication and preference write.
/// A background transition locks it; only device authentication clears it.
class AppLock extends ChangeNotifier {
  AppLock({LocalAuthentication? auth}) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;
  bool ready = false;
  bool enabled = false;
  bool locked = true;
  bool busy = false;
  int _backgroundRevision = 0;
  String? error;
  static const _key = 'ios_app_lock';

  Future<void> load() async {
    try {
      enabled = (await SharedPreferences.getInstance()).getBool(_key) ?? false;
      locked = enabled;
      ready = true;
      error = null;
    } catch (_) {
      error = appL10n.iosAuthFailed;
    }
    notifyListeners();
  }

  void lock() {
    _backgroundRevision++;
    if (enabled) {
      locked = true;
      notifyListeners();
    }
  }

  Future<void> authenticate({bool? enable}) async {
    if (busy) return;
    final revision = _backgroundRevision;
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (!await _auth.isDeviceSupported()) {
        error = appL10n.iosAuthUnavailable;
        return;
      }
      // biometricOnly defaults to false: unavailable/locked-out biometrics
      // retain the OS passcode recovery path. Never create an app-owned PIN.
      final accepted = await _auth.authenticate(localizedReason: appL10n.iosUnlock);
      if (!accepted) {
        error = appL10n.iosAuthFailed;
        return;
      }
      if (revision != _backgroundRevision) {
        error = appL10n.iosAuthFailed;
        return;
      }
      if (enable != null) {
        final saved = await (await SharedPreferences.getInstance()).setBool(_key, enable);
        if (!saved) throw StateError('app_lock_preference_write_failed');
        enabled = enable;
      }
      locked = false;
    } catch (_) {
      error = appL10n.iosAuthFailed;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}

final appLockProvider = Provider<AppLock>((ref) {
  final lock = AppLock();
  // Owned for the application's lifetime, including while routes are hidden.
  return lock;
});
