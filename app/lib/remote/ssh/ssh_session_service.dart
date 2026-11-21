// One authenticated SSH connection for the server file browser and the SSH
// terminal, independent of DSH.
//
// It is deliberately not [SshHostLink]: no DSH probe, no start, no tunnel and
// no DSH login, so files and the terminal keep working while the remote DSH is
// stopped. It opens on first use, pings to notice a dead link, and reports the
// loss instead of replaying anything: a lost write or terminal byte is the
// caller's decision to retry, never this layer's.

import 'dart:async';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import 'ssh_host_config.dart';
import 'ssh_link.dart' show checkHostKey, hostKeyMismatchError, HostKeyVerdict;
import 'ssh_session_capabilities.dart';
import 'ssh_transport.dart';

/// The SSH half of a host: auth and host-key pinning only.
class SshSessionService {
  SshSessionService({
    required this.config,
    required this.loadSecrets,
    required this.transportFactory,
    this.keepAliveInterval = const Duration(seconds: 15),
    this.keepAliveTimeout = const Duration(seconds: 8),
  });

  final SshHostConfig config;
  final Future<SshSecrets> Function() loadSecrets;
  final SshTransportFactory transportFactory;
  final Duration keepAliveInterval;
  final Duration keepAliveTimeout;

  final _lost = StreamController<void>.broadcast();
  SshTransport? _transport;
  Future<SshTransport>? _opening;
  Timer? _ping;
  int _missed = 0;
  bool _closed = false;

  bool get isClosed => _closed;

  bool get connected {
    final transport = _transport;
    return transport != null && !transport.isClosed;
  }

  /// Fires when a live connection died (keepalive miss, socket end). The next
  /// [acquire] opens a new one; nothing is replayed automatically.
  Stream<void> get lost => _lost.stream;

  /// The current connection, opening one when needed. Failures are reported to
  /// the caller; a second caller during the same attempt shares it.
  Future<SshTransport> acquire() {
    if (_closed) return Future.error(StateError('SSH session closed'));
    final live = _transport;
    if (live != null && !live.isClosed) return Future.value(live);
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  /// Drops a dead connection and opens a new one (explicit retry).
  Future<SshTransport> reconnect() {
    _drop();
    return acquire();
  }

  Future<SshFileSession> openFiles() async {
    final host = _capabilities(await acquire());
    return host.openSftp();
  }

  Future<SshPtySession> openPty({SshPtyOptions options = const SshPtyOptions()}) async {
    final host = _capabilities(await acquire());
    return host.openPty(options);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _opening = null;
    _drop();
    await _lost.close();
  }

  Future<SshTransport> _open() async {
    final secrets = await loadSecrets();
    final transport = await transportFactory(SshConnectParams.of(config, secrets), _verifyHostKey);
    if (_closed) {
      transport.close();
      throw StateError('SSH session closed');
    }
    _install(transport);
    return transport;
  }

  /// No prompt here: the host was pinned when it was added (test connection or
  /// the host sheet). An unknown key fails closed instead of asking from a page
  /// that has no business starting an SSH session by itself.
  FutureOr<bool> _verifyHostKey(PresentedHostKey key) {
    return switch (checkHostKey(config, key)) {
      HostKeyVerdict.trusted => true,
      HostKeyVerdict.mismatch => throw hostKeyMismatchError(config, key),
      HostKeyVerdict.unknown => throw HostLinkError(
        HostLinkErrorKind.hostKeyUnverified,
        appL10n.remoteErrFingerprintUnconfirmed,
        detail: '${key.shortType} ${key.fingerprint}',
      ),
    };
  }

  SshSessionHost _capabilities(SshTransport transport) {
    if (transport is SshSessionHost) {
      final host = transport as SshSessionHost;
      if (host.supportsSftp || host.supportsPty) return host;
    }
    throw StateError('this SSH connection has no file or terminal support');
  }

  void _install(SshTransport transport) {
    _transport = transport;
    _missed = 0;
    unawaited(transport.done.then((_) {
      if (identical(transport, _transport)) _drop();
    }));
    _ping?.cancel();
    _ping = Timer.periodic(keepAliveInterval, (_) => unawaited(_tick(transport)));
  }

  Future<void> _tick(SshTransport transport) async {
    if (!identical(transport, _transport) || transport.isClosed) return;
    try {
      await transport.ping(timeout: keepAliveTimeout);
      _missed = 0;
    } catch (_) {
      _missed++;
      // One lost ping is a blip; two in a row mean this socket is gone.
      if (_missed >= 2 && identical(transport, _transport)) _drop();
    }
  }

  void _drop() {
    _ping?.cancel();
    _ping = null;
    _missed = 0;
    final transport = _transport;
    _transport = null;
    transport?.close();
    if (!_lost.isClosed) _lost.add(null);
  }
}
