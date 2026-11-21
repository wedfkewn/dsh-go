// SSH terminal tabs over the SSH connection that does not need DSH.
//
// One tab is one interactive shell on the server. Output is forwarded as raw
// bytes; the page owns the terminal emulation and key mapping (the existing
// xterm widgets). A lost connection ends the tab: the shell on the far side is
// gone with the channel, so nothing reconnects or replays keystrokes
// automatically — the person opens a new tab, exactly like closing a terminal
// window.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHChannelOpenError, SSHChannelRequestError, SSHStateError;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/ssh/ssh_session_capabilities.dart';
import '../remote/ssh/ssh_session_service.dart';
import 'hosts_state.dart';
import 'ssh_session_state.dart';

enum SshTabStatus { starting, running, ended, failed }

class SshTerminalTab {
  const SshTerminalTab({
    required this.id,
    required this.status,
    this.title,
    this.exitCode,
    this.failure,
  });

  final String id;
  final SshTabStatus status;

  /// Page-provided label; null lets the page number it.
  final String? title;

  /// Shell exit status once it ended (null when the server reported none).
  final int? exitCode;
  final SshFailure? failure;

  bool get active => status == SshTabStatus.running || status == SshTabStatus.starting;

  SshTerminalTab copyWith({SshTabStatus? status, String? title, int? exitCode, SshFailure? failure}) =>
      SshTerminalTab(
        id: id,
        status: status ?? this.status,
        title: title ?? this.title,
        exitCode: exitCode ?? this.exitCode,
        failure: failure ?? this.failure,
      );
}

/// A terminal failure, text-free so the page picks the words.
class SshFailure implements Exception {
  const SshFailure(this.kind, {this.detail});

  final SshFailureKind kind;
  final String? detail;

  @override
  String toString() => detail == null ? 'SshFailure($kind)' : 'SshFailure($kind): $detail';
}

enum SshFailureKind { notConnected, connectionLost, unsupported, ptyRefused, other }

SshFailure sshFailureOf(Object error) {
  if (error is SshFailure) return error;
  if (error is HostLinkError) {
    return SshFailure(
      error.retryable ? SshFailureKind.connectionLost : SshFailureKind.notConnected,
      detail: error.message,
    );
  }
  // The server refused the shell/pty: the connection is fine, this tab is not.
  if (error is SSHChannelRequestError) {
    return SshFailure(SshFailureKind.ptyRefused, detail: error.message);
  }
  // The channel or the connection died while setting the pty up.
  if (error is SSHChannelOpenError || error is SSHStateError) {
    return SshFailure(SshFailureKind.connectionLost, detail: '$error');
  }
  return SshFailure(SshFailureKind.other, detail: '$error');
}

class SshTerminalsState {
  const SshTerminalsState({this.tabs = const [], this.activeId, this.failure});

  final List<SshTerminalTab> tabs;
  final String? activeId;

  /// A failure that belongs to the whole page (opening the connection).
  final SshFailure? failure;

  SshTerminalTab? get active {
    for (final tab in tabs) {
      if (tab.id == activeId) return tab;
    }
    return tabs.isEmpty ? null : tabs.last;
  }

  SshTerminalsState copyWith({List<SshTerminalTab>? tabs, String? activeId, SshFailure? failure, bool clearFailure = false}) =>
      SshTerminalsState(
        tabs: tabs ?? this.tabs,
        activeId: activeId ?? this.activeId,
        failure: clearFailure ? null : (failure ?? this.failure),
      );
}

/// Output of one tab. A broadcast stream would drop the banner and prompt
/// printed between the pty opening and the page subscribing, so bytes wait
/// until the first listener.
class _TabOutput {
  _TabOutput() {
    _controller = StreamController<Uint8List>.broadcast(onListen: _flush);
  }

  late final StreamController<Uint8List> _controller;
  final List<Uint8List> _pending = [];

  void add(Uint8List data) {
    if (_controller.hasListener) {
      _controller.add(data);
      return;
    }
    _pending.add(data);
  }

  void _flush() {
    if (_pending.isEmpty) return;
    for (final data in _pending) {
      _controller.add(data);
    }
    _pending.clear();
  }

  Future<void> close() => _controller.close();

  Stream<Uint8List> get stream => _controller.stream;
}

class SshTerminalsController extends Notifier<SshTerminalsState> {
  SshTerminalsController(this.host);

  final HostRef host;

  SshSessionService? _service;
  final Map<String, SshPtySession> _sessions = {};
  final Map<String, StreamSubscription<Uint8List>> _outputSubs = {};
  final Map<String, _TabOutput> _outputs = {};
  StreamSubscription<void>? _lost;
  var _seq = 0;
  var _disposed = false;

  @override
  SshTerminalsState build() {
    // Watched: this page keeps the shared SSH session alive; it closes when
    // the last file/terminal page goes away.
    _service = ref.watch(sshSessionServiceProvider(host));
    ref.onDispose(() {
      _disposed = true;
      unawaited(_lost?.cancel());
      _lost = null;
      for (final session in _sessions.values) {
        session.close();
      }
      _sessions.clear();
      for (final sub in _outputSubs.values) {
        unawaited(sub.cancel());
      }
      _outputSubs.clear();
      for (final controller in _outputs.values) {
        unawaited(controller.close());
      }
      _outputs.clear();
    });
    if (host.kind != HostKind.ssh) {
      return const SshTerminalsState(failure: SshFailure(SshFailureKind.unsupported));
    }
    return const SshTerminalsState();
  }

  /// Output of one tab; subscribing flushes what the shell already printed.
  Stream<Uint8List> outputOf(String id) => _outputs.putIfAbsent(id, _TabOutput.new).stream;

  /// Opens a new shell tab. A refused pty is reported on the tab, not as a
  /// connection failure of the whole page.
  Future<String> openTab({String? title, String? shellPath, int columns = 80, int rows = 24}) async {
    final id = 'tab-${_seq++}';
    state = state.copyWith(
      tabs: [
        ...state.tabs,
        SshTerminalTab(id: id, status: SshTabStatus.starting, title: title),
      ],
      activeId: id,
      clearFailure: true,
    );
    final output = _outputs.putIfAbsent(id, _TabOutput.new);
    try {
      final service = _service;
      if (service == null) throw const SshFailure(SshFailureKind.unsupported);
      _lost ??= service.lost.listen((_) => _onLost());
      final session = await service.openPty(
        options: SshPtyOptions(columns: columns, rows: rows),
      );
      if (_disposed) {
        session.close();
        return id;
      }
      _sessions[id] = session;
      _outputSubs[id] = session.output.listen(
        output.add,
        onError: (Object error) => _end(id, SshTabStatus.failed, failure: sshFailureOf(error)),
        onDone: () => _end(id, SshTabStatus.ended),
      );
      unawaited(
        session.exitCode.then((code) {
          if (_sessions.containsKey(id)) _end(id, SshTabStatus.ended, exitCode: code);
        }),
      );
      _patch(id, (tab) => tab.copyWith(status: SshTabStatus.running));
    } catch (error) {
      _patch(
        id,
        (tab) => tab.copyWith(status: SshTabStatus.failed, failure: sshFailureOf(error)),
      );
    }
    return id;
  }

  /// Sends keystrokes. No buffering across a dead connection: the write fails
  /// with the channel and is not replayed.
  void write(String id, String data) {
    final session = _sessions[id];
    if (session == null) return;
    session.write(utf8.encode(data));
  }

  /// Tells the remote pty the window changed (the page calls this on rotation
  /// and keyboard changes).
  void resize(String id, {required int columns, required int rows}) {
    _sessions[id]?.resize(columns: columns, rows: rows);
  }

  Future<void> closeTab(String id) async {
    final session = _sessions.remove(id);
    session?.close();
    unawaited(_outputSubs.remove(id)?.cancel());
    final output = _outputs.remove(id);
    if (output != null) await output.close();
    if (_disposed) return;
    final tabs = [
      for (final tab in state.tabs)
        if (tab.id != id) tab,
    ];
    state = state.copyWith(
      tabs: tabs,
      activeId: state.activeId == id ? (tabs.isEmpty ? null : tabs.last.id) : state.activeId,
    );
  }

  void setActive(String? id) {
    state = state.copyWith(activeId: id);
  }

  /// Explicit retry for opening a shell (or reconnecting) — always a new tab
  /// or a fresh shell, never a replay of what was typed.
  Future<String> reconnect() async {
    // Drops the dead connection and opens a new one. A fresh shell, never a
    // replay of what was typed before the loss.
    await _service?.reconnect();
    return openTab(title: state.active?.title);
  }

  void _patch(String id, SshTerminalTab Function(SshTerminalTab) update) {
    if (_disposed) return;
    state = state.copyWith(
      tabs: [
        for (final tab in state.tabs)
          if (tab.id == id) update(tab) else tab,
      ],
    );
  }

  void _end(String id, SshTabStatus status, {int? exitCode, SshFailure? failure}) {
    final session = _sessions.remove(id);
    session?.close();
    unawaited(_outputSubs.remove(id)?.cancel());
    final output = _outputs.remove(id);
    if (output != null) unawaited(output.close());
    _patch(id, (tab) => tab.copyWith(status: status, exitCode: exitCode, failure: failure));
  }

  void _onLost() {
    for (final id in [..._sessions.keys]) {
      _end(id, SshTabStatus.ended, failure: const SshFailure(SshFailureKind.connectionLost));
    }
    if (_disposed) return;
    state = state.copyWith(failure: const SshFailure(SshFailureKind.connectionLost));
  }
}

/// Terminal tabs of one SSH host; switching hosts never shares shells.
final sshTerminalsProvider = NotifierProvider.autoDispose.family<SshTerminalsController, SshTerminalsState, HostRef>(
  SshTerminalsController.new,
);
