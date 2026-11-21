import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../remote/ssh/dsh_discovery.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The instances a scan found: one row each, ports and whether this app
/// started it. Picking one fills the attach form; an instance with no
/// listening port stays visible but cannot be picked (the tunnel needs one).
/// Null when the sheet is dismissed without a choice.
Future<RemoteDshInstance?> showAttachInstancesSheet(
  BuildContext context, {
  required List<RemoteDshInstance> instances,
}) {
  final l10n = context.l10n;
  return showAppSheet<RemoteDshInstance>(
    context,
    isScrollControlled: true,
    builder: (sheet) {
      final theme = Theme.of(sheet);
      final colors = DshColors.of(sheet);
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.remoteDiscoverSelectTitle),
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 10),
                child: Text(
                  l10n.remoteDiscoverSelectBody,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    SheetGroup(
                      children: [
                        for (final instance in instances)
                          SettingsTile(
                            icon: AppIcons.terminal,
                            tinted: false,
                            title: instance.command,
                            subtitle: _subtitle(context, instance),
                            trailing: instance.token == null
                                ? null
                                : Icon(AppIcons.lock, size: 18, color: colors.success),
                            onTap: instance.attachable ? () => Navigator.pop(sheet, instance) : null,
                          ),
                      ],
                    ),
                    if (instances.any((i) => i.token == null))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 2, SheetTitleBar.inset, 12),
                        child: Text(
                          l10n.remoteDiscoverManualTokenHint,
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

String _subtitle(BuildContext context, RemoteDshInstance instance) {
  final l10n = context.l10n;
  final ports = instance.ports.isEmpty
      ? l10n.remoteDiscoverNoPort
      : '${l10n.remoteDiscoverPorts} ${instance.ports.join(', ')}';
  return [
    'PID ${instance.pid}',
    ports,
    if (instance.managed) l10n.remoteDiscoverManaged,
    if (instance.token != null) l10n.remoteDiscoverTokenKnown,
  ].join(' · ');
}
