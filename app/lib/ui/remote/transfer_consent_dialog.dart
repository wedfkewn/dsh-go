import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../remote/transfer_consent.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();

Future<bool> confirmRemoteTransfer(RemoteTransfer transfer) async {
  final context = appNavigatorKey.currentContext;
  if (context == null) return false;
  final l10n = context.l10n;
  return await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.remoteTransferConfirmTitle),
      content: SingleChildScrollView(child: Text('${transfer.destination}\n\n${transfer.items.join('\n')}\n\n${l10n.remoteTransferConfirmHelp}')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.remoteTransferConfirmSend)),
      ],
    ),
  ) ?? false;
}
