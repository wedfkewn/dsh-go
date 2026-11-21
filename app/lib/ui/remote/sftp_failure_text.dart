import '../../l10n/l10n.dart';
import '../../state/sftp_state.dart';

/// Failure words for every [SftpFailureKind]; the state layer keeps none.
String sftpFailureText(L10n l10n, SftpFailure failure) => switch (failure.kind) {
  SftpFailureKind.notConnected => l10n.remoteServerFilesDisconnected,
  SftpFailureKind.connectionLost => l10n.remoteServerFilesDisconnected,
  SftpFailureKind.notFound => l10n.remoteServerFilesNotFound,
  SftpFailureKind.permissionDenied => l10n.remoteServerFilesPermissionDenied,
  SftpFailureKind.alreadyExists => l10n.remoteServerFilesAlreadyExists,
  SftpFailureKind.notEmpty => l10n.remoteServerFilesNotEmpty,
  SftpFailureKind.isDirectory => l10n.remoteServerFilesIsDirectory,
  SftpFailureKind.unsupported => l10n.remoteServerFilesUnsupported,
  SftpFailureKind.tooLarge => l10n.remoteServerFilesTooLarge,
  SftpFailureKind.cancelled => l10n.remoteServerFilesCancelled,
  SftpFailureKind.other => failure.detail ?? l10n.remoteServerFilesOperationFailed,
};
