import 'package:dsh_app/runtime/local_runtime_service.dart';
import 'package:dsh_app/runtime/native_node/native_node_runtime_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/native_node');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('placeholder does not report a running runtime', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => {
      'phase': 'unimplemented',
      'error': {
        'code': 'native_node_unavailable',
        'message': 'NodeMobile is not linked.',
      },
    });
    final status = await NativeNodeRuntimeService().status();
    expect(status.phase, LocalRuntimeServicePhase.unimplemented);
    expect(status.error?.code, 'native_node_unavailable');
  });

  test('native operation failures propagate without fake success', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'native_node_unavailable');
    });
    final service = NativeNodeRuntimeService();
    for (final operation in <Future<void> Function()>[
      service.start,
      service.stop,
      service.restart,
    ]) {
      await expectLater(
        operation(),
        throwsA(isA<PlatformException>().having(
          (value) => value.code,
          'code',
          'native_node_unavailable',
        )),
      );
    }
  });

  test('missing native registration fails closed', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw MissingPluginException();
    });
    final service = NativeNodeRuntimeService();
    await expectLater(
      service.status(),
      throwsA(isA<PlatformException>().having(
        (value) => value.code,
        'code',
        'native_node_not_linked',
      )),
    );
    await expectLater(
      service.start(),
      throwsA(isA<PlatformException>().having(
        (value) => value.code,
        'code',
        'native_node_not_linked',
      )),
    );
  });

  test('rejects unverified running status', () async {
    final service = NativeNodeRuntimeService();
    final cases = <Map<String, Object?>>[
      {'phase': 'running'},
      {'phase': 'running', 'baseUrl': 'http://127.0.0.1:8000'},
      {'phase': 'running', 'baseUrl': 'https://example.com:443', 'token': 'x'},
      {'phase': 'running', 'baseUrl': 'http://127.0.0.1:8000', 'token': ''},
      {'phase': 'running', 'baseUrl': 'http://127.0.0.1', 'token': 'x'},
      {'phase': 'unexpected'},
    ];
    for (final value in cases) {
      messenger.setMockMethodCallHandler(channel, (_) async => value);
      await expectLater(
        service.statusMap(),
        throwsA(isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'native_node_status_invalid_response',
        )),
      );
    }
  });

  test('accepts a verified-shape localhost status', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {
      'phase': 'running',
      'baseUrl': 'http://127.0.0.1:8080',
      'token': 'test-only',
      'nodeVersion': '24.x',
    });
    final service = NativeNodeRuntimeService();
    final map = await service.statusMap();
    expect(map['nodeVersion'], '24.x');
    expect((await service.status()).phase, LocalRuntimeServicePhase.running);
  });

  test('rejects malformed error maps', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {
      'phase': 'error',
      'error': {'code': 42, 'message': 'error'},
    });
    await expectLater(
      NativeNodeRuntimeService().status(),
      throwsA(isA<PlatformException>().having(
        (error) => error.code,
        'code',
        'native_node_status_invalid_response',
      )),
    );
  });
}
