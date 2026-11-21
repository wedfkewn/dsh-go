import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/app_dialog.dart';
import '../theme/theme.dart';

/// Confirms stopping the DSH this app started on a server. Only the managed
/// instance is ever touched; the body says so before the destructive button.
Future<bool> confirmStopManaged(BuildContext context, {required String hostName}) async {
  final l10n = context.l10n;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.remoteStopManagedTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.remoteStopManagedBody),
          const SizedBox(height: 10),
          Text(
            hostName,
            style: Theme.of(dialog).textTheme.bodySmall?.copyWith(color: DshColors.of(dialog).textTertiary),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: DshColors.of(dialog).danger,
            foregroundColor: DshColors.of(dialog).onDanger,
          ),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(l10n.remoteStopManaged),
        ),
      ],
    ),
  );
  return ok ?? false;
}
