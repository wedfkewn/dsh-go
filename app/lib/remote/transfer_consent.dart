import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One concrete outbound operation. Approval is never cached or persisted.
class RemoteTransfer {
  const RemoteTransfer({required this.destination, required this.items});
  final String destination;
  final List<String> items;
}

/// Headless/background callers fail closed. The app supplies the dialog.
final remoteTransferConsentProvider = Provider<Future<bool> Function(RemoteTransfer)>(
  (ref) => (_) async => false,
);
