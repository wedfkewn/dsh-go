// 保留窗口边界（独立验证，不依赖运行日期）。
//
// 规则：链接到期后仍列出「已过期」30 天，从到期满 30 天的那一刻起清理。
// 判定是严格 isAfter(cutoff)：
//   expiresAt == now - 30d      → 清理（边界本身不保留）
//   expiresAt == now - 30d + 1µs → 保留
// 普通加载（_loadPlain）与 HarmonyOS 加载（_load）用同一个可注入时钟，
// 生产默认仍是墙上时间。

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/share_hosted/hosted_client.dart';
import 'package:dsh_app/share_hosted/hosted_link.dart';
import 'package:dsh_app/share_hosted/hosted_links_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/share_hosted/hosted_links_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'hosted_client_test.dart' show FakeHost;
import 'hosted_links_state_test.dart' show MemoryStore, link;

final _now = DateTime(2026, 11, 21, 12);

const _kept = ['K000000001', 'K000000002', 'F000000006'];

List<HostedLink> _fixture() => [
  link('K000000001', expires: _now.subtract(const Duration(days: 28))), // 过期 28 天：窗口内
  link('K000000002', expires: _now.subtract(const Duration(days: 30, microseconds: -1))), // 窗口内 1µs
  link('A000000003', expires: _now.subtract(const Duration(days: 30))), // 边界整点：清理
  link('A000000004', expires: _now.subtract(const Duration(days: 30, microseconds: 1))), // 窗口外 1µs：清理
  link('A000000005', expires: _now.subtract(const Duration(days: 40))), // 早就过了窗口
  link('F000000006'), // 永久：不参与窗口
];

(ProviderContainer, MemoryStore) _container(List<HostedLink> saved, {String? os}) {
  final host = FakeHost();
  final store = MemoryStore(saved);
  final container = ProviderContainer(
    overrides: [
      hostedLinkStoreProvider.overrideWithValue(store),
      hostedShareClientProvider.overrideWithValue(HostedShareClient(client: host.client, origin: 'https://go.example')),
      hostedLinksClockProvider.overrideWithValue(() => _now),
      if (os != null) operatingSystemProvider.overrideWithValue(os),
    ],
  );
  addTearDown(container.dispose);
  return (container, store);
}

void main() {
  test('within the window keeps expired links; the boundary itself is cleaned (plain load)', () async {
    final (container, store) = _container(_fixture());
    await container.read(hostedLinksProvider.notifier).ready;
    expect(container.read(hostedLinksProvider).links.map((l) => l.id), _kept);
    // 清理结果也落盘：被剔除的三条从存储里消失。
    expect(store.saved.map((l) => l.id), _kept);
    expect(store.saves, 1);
  });

  test('HarmonyOS load applies the same boundary', () async {
    final (container, store) = _container(_fixture(), os: 'ohos');
    await container.read(hostedLinksProvider.notifier).ready;
    expect(container.read(hostedLinksProvider).links.map((l) => l.id), _kept);
    expect(store.saved.map((l) => l.id), _kept);
  });

  test('nothing outside the window means no rewrite', () async {
    final (container, store) = _container([
      link('K000000001', expires: _now.subtract(const Duration(days: 30, microseconds: -1))),
      link('G000000002', expires: _now.subtract(const Duration(days: 1))),
      link('F000000003'),
    ]);
    await container.read(hostedLinksProvider.notifier).ready;
    expect(container.read(hostedLinksProvider).links.map((l) => l.id), ['K000000001', 'G000000002', 'F000000003']);
    expect(store.saves, 0);
  });

  test('production clock is still the wall clock', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final clock = container.read(hostedLinksClockProvider);
    expect(clock().difference(DateTime.now()).inSeconds.abs(), lessThanOrEqualTo(1));
  });

  testWidgets('the page words kept expired rows 已过期 and drops cleaned ones', (tester) async {
    usePhoneView(tester);
    final host = FakeHost();
    final store = MemoryStore(_fixture());
    await tester.pumpWidget(
      testApp(
        HostedLinksPage(clock: () => _now),
        overrides: [
          hostedLinkStoreProvider.overrideWithValue(store),
          hostedShareClientProvider.overrideWithValue(
            HostedShareClient(client: host.client, origin: 'https://go.example'),
          ),
          hostedLinksClockProvider.overrideWithValue(() => _now),
        ],
      ),
    );
    await pumpFrames(tester, 6);
    // 两条窗口内的过期链接都在，仍可看到「已过期」；永久链接照常。
    expect(find.text('对话 K000000001'), findsOneWidget);
    expect(find.text('对话 K000000002'), findsOneWidget);
    expect(find.text(appL10n.remoteHostedExpired), findsNWidgets(2));
    expect(find.text(appL10n.remoteHostedNeverExpires), findsOneWidget);
    // 三条出了窗口的不显示，也不在存储里。
    for (final id in ['A000000003', 'A000000004', 'A000000005']) {
      expect(find.text('对话 $id'), findsNothing);
      expect(store.saved.map((l) => l.id), isNot(contains(id)));
    }
    // 过期链接只能删，不能复制。
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('hosted-copy-K000000001'))).onPressed, isNull);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('hosted-copy-F000000006'))).onPressed, isNotNull);
  });
}
