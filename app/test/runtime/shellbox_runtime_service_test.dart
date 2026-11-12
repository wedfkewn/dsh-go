import 'package:dsh_app/runtime/local_runtime_service.dart';
import 'package:dsh_app/runtime/shellbox/shellbox_runtime_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/shellbox');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final service = ShellBoxRuntimeService();

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('lifecycle preserves native operation-specific failures', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'shellbox_${call.method}_unimplemented');
    });
    for (final operation in <String, Future<void> Function()>{
      'start': service.start,
      'stop': service.stop,
      'restart': service.restart,
    }.entries) {
      await expectLater(
        operation.value(),
        throwsA(isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'shellbox_${operation.key}_unimplemented',
        )),
      );
    }
    expect(calls, ['start', 'stop', 'restart']);
  });

  test('status reflects native error without asserting readiness', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'status');
      return {
        'phase': 'unimplemented',
        'error': {
          'code': 'shellbox_start_rootfs_unimplemented',
          'message': 'No prepared payload.',
        },
      };
    });
    final status = await service.status();
    expect(status.phase, LocalRuntimeServicePhase.unimplemented);
    expect(status.error?.code, 'shellbox_start_rootfs_unimplemented');
    expect(status.error?.message, 'No prepared payload.');
  });

  test('unsupported status fails instead of implying success', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {'phase': 'running'});
    await expectLater(
      service.status(),
      throwsA(isA<PlatformException>().having(
        (error) => error.code,
        'code',
        'shellbox_status_invalid_response',
      )),
    );
  });
}
