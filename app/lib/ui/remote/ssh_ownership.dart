import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../../remote/ssh/ssh_host_config.dart';
import '../../remote/ssh/ssh_link.dart';

/// The persistent ownership label for an SSH host: who started the DSH the
/// app talks to. Attach never starts or stops anything — it is the user's
/// instance; Managed is the one this app started. Null for relay hosts and for
/// a host config that is not loaded yet.
String? sshOwnershipLabel(BuildContext context, SshHostConfig? config, {SshDshOwnership? ownership}) {
  final l10n = context.l10n;
  switch (ownership) {
    case SshDshOwnership.attached:
      return l10n.remoteOwnershipAttach;
    case SshDshOwnership.managedStarted:
      return l10n.remoteOwnershipManagedStarted;
    case SshDshOwnership.managedReused:
      return l10n.remoteOwnershipManagedReused;
    case null:
      break;
  }
  if (config == null) return null;
  return config.dshMode == SshDshMode.attachOnly ? l10n.remoteOwnershipAttach : l10n.remoteOwnershipManaged;
}
