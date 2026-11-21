// The SSH session of one host, shared by the server file browser and the SSH
// terminal inside a page session. It is separate from the DSH link on purpose:
// files and shells keep working while the remote DSH is stopped.
//
// The provider is watched (not read) by [SftpController] and
// [SshTerminalsController], so it stays alive exactly while one of those pages
// is open and closes its connection when the last one goes away. Tests
// override it with a service built on a fake transport.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/ssh/ssh_session_service.dart';
import 'connection_state.dart';
import 'hosts_state.dart';

/// Null for 本机, relay hosts and a host that is no longer saved.
final sshSessionServiceProvider = Provider.autoDispose.family<SshSessionService?, HostRef>((ref, host) {
  if (host.kind != HostKind.ssh) return null;
  final config = ref.watch(hostsProvider.select((s) => s.sshById(host.id)));
  if (config == null) return null;
  final hosts = ref.read(hostsProvider.notifier);
  final service = SshSessionService(
    config: config,
    loadSecrets: () => hosts.loadSecrets(host.id),
    transportFactory: ref.read(sshTransportFactoryProvider),
  );
  ref.onDispose(() => unawaited(service.close()));
  return service;
});
