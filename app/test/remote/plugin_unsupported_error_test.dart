// When the host or the relay cannot manage plugins, the person must be told
// what actually happened — "这台主机不允许远程安装", "主机不支持插件管理",
// "当前引擎版本不支持" — instead of a generic "操作没完成". These checks pin the
// mapping from the real errors to that copy, and pin that the plugin inventory
// page shows the cause it got rather than an empty list.

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/plugin_inventory_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

HostConnection _connected() => HostConnection(
  client: DshClient(DshConnection(Uri.parse('http://127.0.0.1:9'))),
  isLocal: false,
  kind: HostKind.ssh,
  hostId: 'lab',
  name: '实验室服务器',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('插件错误文案', () {
    test('a relay that only allows toggling says so, instead of failing generically', () {
      final failure = describePluginError(const DshRemoteException('METHOD_NOT_ALLOWED', 'not allowed'));

      expect(failure.kind, PluginFailureKind.unsupported);
      expect(failure.title, '这台主机不允许远程安装');
      expect(failure.message, '经中转连接只能开关插件');
      expect(failure.retryable, isFalse, reason: '换一次连接也不会变，不要引导重试');
    });

    test('an engine without plugin management names the engine, and keeps the code', () {
      final failure = describePluginError(
        const DshRemoteException('gateway/method-not-found', 'No such method: pluginInventory/list'),
      );

      expect(failure.kind, PluginFailureKind.unsupported);
      expect(failure.title, '主机不支持插件管理');
      expect(failure.message, '当前引擎不支持插件管理');
      expect(failure.detail, contains('gateway/method-not-found'), reason: '诊断信息留给展开详情');
    });

    test('an older host answering 404 is unsupported, not a save failure', () {
      final failure = describePluginError(const DshHttpException(404, 'missing'));

      expect(failure.kind, PluginFailureKind.unsupported);
      expect(failure.title, '主机不支持插件管理');
    });

    test('an unrecognized code keeps its raw detail instead of swallowing it', () {
      final failure = describePluginError(const DshRemoteException('some/other', 'boom'));

      expect(failure.kind, PluginFailureKind.unknown);
      expect(failure.retryable, isTrue);
      expect(failure.detail, contains('some/other: boom'));
    });
  });

  group('插件清单页', () {
    Future<void> pumpInventory(WidgetTester tester, Object error) async {
      await tester.pumpWidget(
        goldenApp(
          home: const PluginInventoryPage(),
          brightness: Brightness.light,
          overrides: [
            activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(_connected())),
            pluginInventoryProvider.overrideWith((ref) => Future<InventorySnapshot?>.error(error)),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a relay refusal says plugins are toggle-only, not a rejected value', (tester) async {
      await pumpInventory(tester, const DshRemoteException('METHOD_NOT_ALLOWED', 'Not allowed.'));

      expect(find.text('没能读取插件清单'), findsOneWidget);
      expect(find.text('经中转连接只能开关插件'), findsOneWidget, reason: '要说明中转下只能开关插件');
      expect(find.text('引擎没有接受这个值'), findsNothing, reason: '不要再显示设置页的通用文案');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('shows the unsupported reason the host returned, not a generic failure', (tester) async {
      await pumpInventory(tester, const DshRemoteException('gateway/method-not-found', 'No such method'));

      expect(find.text('没能读取插件清单'), findsOneWidget);
      expect(find.text('当前引擎版本不支持'), findsOneWidget, reason: '要显示主机给出的真实原因');
      expect(find.textContaining('保存'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('an HTTP refusal shows the status the host answered with', (tester) async {
      await pumpInventory(tester, const DshHttpException(403, 'forbidden'));

      expect(find.text('没能读取插件清单'), findsOneWidget);
      expect(find.text('引擎拒绝了请求（403）'), findsOneWidget, reason: 'HTTP 状态本身要露出来');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
