// 通知偏好在 build() 里异步读一次 store（`NotifyPrefsController._load`）。读取可能
// 比使用它的页面/容器活得更久：容器先销毁、prefs 的 Future 后到，此时再写 state
// 会踩到已销毁的 Ref（真实报错：`Cannot use the Ref ... after it has been disposed`，
// 栈落在 notify_state.dart 的 `_load`）。这条用例在容器已销毁后让 prefs 的续帧落地，
// 断言没有异常逃出来——修复前它会以未捕获的 zone 错误让测试失败。

import 'package:dsh_app/state/notify_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a load that lands after the container is gone writes nothing', () async {
    SharedPreferences.setMockInitialValues({});

    final container = ProviderContainer();
    final sub = container.listen(notifyPrefsProvider, (_, _) {});
    // The listen starts the async read; the container goes away before it lands.
    sub.close();
    container.dispose();

    // Let the prefs future resolve and its continuation run. A write through the
    // disposed notifier surfaces here as an uncaught zone error.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('the stored values still arrive on a live container', () async {
    SharedPreferences.setMockInitialValues({
      'notify_enabled': false,
      'notify_continued_run': false,
    });

    final container = ProviderContainer();
    final sub = container.listen(notifyPrefsProvider, (_, _) {});
    addTearDown(sub.close);
    addTearDown(container.dispose);

    NotifyPrefs prefs = container.read(notifyPrefsProvider);
    for (var i = 0; i < 100 && !prefs.loaded; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      prefs = container.read(notifyPrefsProvider);
    }
    expect(prefs.loaded, isTrue, reason: '读取完成后要标记已加载');
    expect(prefs.enabled, isFalse);
    expect(prefs.continuedRun, isFalse);
  });
}
