/// Future platform boundary; intentionally independent of Android channels.
/// Existing RuntimeBridge consumers are not migrated in this first skeleton.
abstract interface class LocalRuntimeService {
  Future<void> start();
  Future<void> stop();
  Future<void> restart();
  Future<LocalRuntimeServiceStatus> status();
}

/// Native lifecycle phases; unimplemented preserves the initial iOS scaffold.
enum LocalRuntimeServicePhase {
  unimplemented,
  notInstalled,
  installing,
  installed,
  starting,
  running,
  stopping,
  error,
}

class LocalRuntimeServiceError {
  const LocalRuntimeServiceError(this.code, this.message);

  final String code;
  final String message;
}

class LocalRuntimeServiceStatus {
  const LocalRuntimeServiceStatus({required this.phase, required this.error});

  final LocalRuntimeServicePhase phase;
  final LocalRuntimeServiceError? error;
}
