import 'dart:async';

import 'package:dsh_app/security/app_lock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAuthentication implements LocalAuthentication {
  bool supported = true;
  Future<bool> Function() answer = () async => true;

  @override
  Future<bool> isDeviceSupported() async => supported;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #authenticate) return answer();
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('default off; opt-in persists only after authentication', () async {
    final auth = FakeAuthentication();
    final lock = AppLock(auth: auth);
    await lock.load();
    expect(lock.enabled, false);
    expect(lock.locked, false);
    auth.answer = () async => false;
    await lock.authenticate(enable: true);
    expect(lock.enabled, false);
    auth.answer = () async => true;
    await lock.authenticate(enable: true);
    expect(lock.enabled, true);
    final restored = AppLock(auth: auth);
    await restored.load();
    expect(restored.locked, true);
    auth.supported = false;
    await restored.authenticate();
    expect(restored.locked, true);
    expect(restored.error, isNotNull);
    auth.supported = true;
    await restored.authenticate();
    expect(restored.locked, false);
    await restored.authenticate(enable: false);
    final disabled = AppLock(auth: auth);
    await disabled.load();
    expect(disabled.enabled, false);
  });

  test('backgrounding during authentication keeps enabled lock closed', () async {
    final auth = FakeAuthentication();
    final lock = AppLock(auth: auth);
    await lock.load();
    await lock.authenticate(enable: true);
    final answer = Completer<bool>();
    auth.answer = () => answer.future;
    final pending = lock.authenticate();
    await Future<void>.delayed(Duration.zero);
    lock.lock();
    answer.complete(true);
    await pending;
    expect(lock.locked, true);
    expect(lock.busy, false);
  });
}
