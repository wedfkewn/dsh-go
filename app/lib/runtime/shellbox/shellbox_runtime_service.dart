import '../local_runtime_service.dart';

/// iOS integration placeholder. Does not invoke ShellBox or start DSH.
final class ShellBoxRuntimeService implements LocalRuntimeService {
  @override
  Future<void> start() => throw UnimplementedError('shellbox_not_implemented');

  @override
  Future<void> stop() => throw UnimplementedError('shellbox_not_implemented');

  @override
  Future<void> restart() => throw UnimplementedError('shellbox_not_implemented');

  @override
  Future<LocalRuntimeServiceStatus> status() async =>
      const LocalRuntimeServiceStatus(
        phase: LocalRuntimeServicePhase.unimplemented,
        error: LocalRuntimeServiceError(
          'shellbox_not_implemented',
          'ShellBox native lifecycle is not implemented.',
        ),
      );
}
