// The ways in from the home screen, checked where they are declared now: the
// iOS app. This replaces the Android manifest test that went with that host —
// same intent (the shipped entry points are registered, and the native and Dart
// sides agree on their names), written against Info.plist and DshPlugin.swift.
//
//   flutter test test/system_entry/ios_system_entry_test.dart

import 'dart:io';

import 'package:dsh_app/links/launcher_entries.dart';
import 'package:flutter_test/flutter_test.dart';

final _info = File('ios/Runner/Info.plist').readAsStringSync();
final _plugin = File('ios/Runner/DshPlugin.swift').readAsStringSync();
final _project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();

List<String> _shortcutTypes() => [
  for (final m in RegExp(
    r'<key>UIApplicationShortcutItemType</key>\s*<string>([^<]+)</string>',
  ).allMatches(_info))
    m.group(1)!,
];

int _count(String source, String pattern) => RegExp(pattern).allMatches(source).length;

void main() {
  test('the bundle id the quick actions are keyed by is the shipped one', () {
    final bundle = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);').firstMatch(_project)!.group(1)!;
    final prefix = RegExp(r'private static let prefix = "([^"]+)"').firstMatch(_plugin)!.group(1)!;
    // The native handler matches on this prefix; a bundle id change that forgets
    // it would leave every quick action dead with no build error.
    expect(prefix, '$bundle.');
    expect(_shortcutTypes().every((t) => t.startsWith(prefix)), isTrue);
  });

  test('新对话 and 语音输入 are declared, and iOS never shows more than four', () {
    final types = _shortcutTypes();
    expect(types, hasLength(2));
    expect(types.map((t) => t.split('.').last), ['new', 'voice']);
    // One title and one icon per item, or the system draws a blank row.
    expect(_count(_info, r'<key>UIApplicationShortcutItemTitle</key>'), 2);
    expect(_count(_info, r'<key>UIApplicationShortcutItemIconSymbolName</key>'), 2);
    // The home screen shows four: the two static ones plus the recent chats the
    // app adds at runtime.
    final recent = int.parse(RegExp(r'private static let recentShown = (\d+)').firstMatch(_plugin)!.group(1)!);
    expect(types.length + recent, lessThanOrEqualTo(4));
  });

  test('the native handler maps each type to the kind Dart parses', () {
    for (final kind in ['new', 'voice']) {
      expect(
        _plugin.contains('case prefix + "$kind": return ["kind": "$kind"]'),
        isTrue,
        reason: 'DshPlugin.swift does not map the $kind quick action',
      );
      final parsed = LauncherEntry.parse({'kind': kind});
      expect(parsed, isA<NewChatEntry>(), reason: kind);
    }
    final voice = LauncherEntry.parse({'kind': 'voice'})! as NewChatEntry;
    expect(voice.voice, isTrue);
    expect((LauncherEntry.parse({'kind': 'new'})! as NewChatEntry).voice, isFalse);
    // A recent chat carries its session and may carry a host; without the id it is
    // dropped rather than opening an empty screen.
    expect(LauncherEntry.parse({'kind': 'chat'}), isNull);
    expect(_plugin.contains('guard let id = item.userInfo?["sessionId"] as? String'), isTrue);
  });

  test('the dshgo link scheme is registered once', () {
    final schemes = [
      for (final m in RegExp(
        r'<key>CFBundleURLSchemes</key>\s*<array>\s*<string>([^<]+)</string>',
      ).allMatches(_info))
        m.group(1)!,
    ];
    expect(schemes, ['dshgo']);
  });

  test('the shortcuts channel is the one Dart listens on', () {
    expect(_plugin.contains('FlutterMethodChannel(name: "dsh/shortcuts"'), isTrue);
    expect(_plugin.contains('channel.invokeMethod("entry", arguments: entry)'), isTrue);
    final bridge = File('lib/links/launcher_entries.dart').readAsStringSync();
    expect(bridge.contains("const MethodChannel('dsh/shortcuts')"), isTrue);
    expect(bridge.contains("method: 'entry'"), isTrue);
  });
}
