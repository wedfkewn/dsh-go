// SSH 终端: interactive shells over the shared SSH session layer
// (`sshTerminalsProvider`), independent of DSH. The page owns only the xterm
// emulation and key mapping; opening, resizing, ending and closing tabs live
// in the state layer. A lost connection ends the tab — the person opens a new
// one explicitly, nothing is replayed.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/l10n.dart';
import '../../remote/ssh/remote_shell.dart' show shQuote;
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/ssh_terminal_state.dart';
import '../shell/page_frame.dart';
import '../terminal/terminal_keys.dart';
import '../terminal/terminal_palette.dart';
import '../terminal/terminal_screen.dart' show TerminalCardFrame;
import '../theme/app_icons.dart';
import '../theme/theme.dart';

class SshTerminalPage extends ConsumerStatefulWidget {
  const SshTerminalPage({super.key, required this.host, this.initialDirectory});

  final HostRef host;

  /// Change into this server directory once the first shell is up.
  final String? initialDirectory;

  static Route<void> route(HostRef host, {String? initialDirectory}) => MaterialPageRoute<void>(
    builder: (_) => SshTerminalPage(host: host, initialDirectory: initialDirectory),
  );

  @override
  ConsumerState<SshTerminalPage> createState() => _SshTerminalPageState();
}

class _SshTerminalPageState extends ConsumerState<SshTerminalPage> {
  final _terminals = <String, Terminal>{};
  final _outputs = <String, StreamSubscription<Uint8List>>{};
  final _focused = <String>{};
  final _focus = FocusNode(debugLabel: 'ssh-terminal');
  final _modifiers = TerminalModifiers();
  bool _opened = false;

  SshTerminalsController get _tabs => ref.read(sshTerminalsProvider(widget.host).notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _opened = true;
      unawaited(_tabs.openTab(columns: 100, rows: 30));
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _modifiers.dispose();
    for (final sub in _outputs.values) {
      unawaited(sub.cancel());
    }
    _outputs.clear();
    super.dispose();
  }

  Terminal _terminalFor(String id) => _terminals.putIfAbsent(id, () {
    final terminal = Terminal(maxLines: 10000);
    terminal.onOutput = (data) => _tabs.write(id, data);
    terminal.onResize = (columns, rows, _, _) => _tabs.resize(id, columns: columns, rows: rows);
    _outputs[id] = _tabs.outputOf(id).listen((bytes) => terminal.write(utf8.decode(bytes, allowMalformed: true)));
    return terminal;
  });

  void _forget(Set<String> live) {
    for (final id in [..._terminals.keys]) {
      if (live.contains(id)) continue;
      _terminals.remove(id);
      _focused.remove(id);
      unawaited(_outputs.remove(id)?.cancel());
    }
  }

  Future<void> _newTab() async {
    await _tabs.openTab(columns: 100, rows: 30);
    if (mounted) setState(() {});
  }

  Future<void> _retry() async {
    await _tabs.reconnect();
    if (mounted) setState(() {});
  }

  void _sendExtraKey(String id, TerminalExtraKey key) {
    final terminal = _terminals[id];
    if (terminal == null) return;
    final m = _modifiers.consume();
    key.send(terminal, ctrl: m.ctrl, alt: m.alt);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = ref.watch(hostNameProvider(widget.host)) ?? l10n.commonRemoteHost;
    final state = ref.watch(sshTerminalsProvider(widget.host));
    final ids = {for (final tab in state.tabs) tab.id};
    _forget(ids);
    final tabs = state.tabs;
    final active = state.active;
    final palette = TerminalPalette.of(context);

    // `cd` once per shell, never on reconnect (a reconnect opens a new tab).
    final dir = widget.initialDirectory;
    if (dir != null && active != null && active.status == SshTabStatus.running && _focused.add(active.id)) {
      _tabs.write(active.id, 'cd ${shQuote(dir)}\n');
    }

    Widget content;
    if (state.failure case final failure?) {
      content = _Message(
        title: sshFailureText(l10n, failure),
        action: l10n.commonRetry,
        onAction: () => unawaited(_retry()),
      );
    } else if (tabs.isEmpty) {
      content = _Message(
        title: l10n.remoteTerminalNone,
        action: _opened ? l10n.remoteTerminalNew : null,
        onAction: _opened ? () => unawaited(_newTab()) : null,
      );
    } else {
      final terminal = _terminalFor(active!.id);
      final live = active.status == SshTabStatus.running || active.status == SshTabStatus.starting;
      content = TerminalCardFrame(
        child: Column(
          children: [
            Expanded(
              child: TerminalView(
                terminal,
                theme: live ? palette.theme : palette.quiet,
                textStyle: const TerminalStyle(
                  fontSize: 13,
                  fontFamily: AppType.monoFamily,
                  fontFamilyFallback: AppType.monoFallback,
                ),
                backgroundOpacity: 0,
                focusNode: _focus,
                autofocus: true,
                readOnly: !live,
                padding: const EdgeInsets.all(12),
                onTapUp: (_, _) => _focus.requestFocus(),
              ),
            ),
            if (!live) TerminalStatusBar(label: _tabStatus(l10n, active)),
            ExtraKeysRow(modifiers: _modifiers, onKey: (key) => _sendExtraKey(active.id, key)),
          ],
        ),
      );
    }

    return AppPage(
      title: l10n.remoteTerminalTitle,
      subtitle: Text(name),
      actions: [
        IconButton(
          tooltip: l10n.remoteTerminalNew,
          onPressed: state.failure == null ? () => unawaited(_newTab()) : null,
          icon: const Icon(AppIcons.add),
        ),
      ],
      slivers: [
        if (tabs.isNotEmpty)
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  for (final tab in tabs)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: InputChip(
                        label: Text(tab.title ?? tab.id),
                        selected: tab.id == active?.id,
                        onPressed: () => _tabs.setActive(tab.id),
                        onDeleted: tabs.length > 1 ? () => unawaited(_tabs.closeTab(tab.id)) : null,
                        deleteIcon: const Icon(AppIcons.close, size: 16),
                        showCheckmark: false,
                      ),
                    ),
                ],
              ),
            ),
          ),
        SliverFillRemaining(
          child: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: content),
        ),
      ],
    );
  }
}

String _tabStatus(L10n l10n, SshTerminalTab tab) => switch (tab.status) {
  SshTabStatus.starting => l10n.remoteTerminalConnecting,
  SshTabStatus.ended => tab.failure == null ? l10n.remoteTerminalEnded : sshFailureText(l10n, tab.failure!),
  SshTabStatus.failed => tab.failure == null ? l10n.remoteTerminalFailed : sshFailureText(l10n, tab.failure!),
  SshTabStatus.running => '',
};

/// Failure words for every [SshFailureKind]; the state layer keeps none.
String sshFailureText(L10n l10n, SshFailure failure) => switch (failure.kind) {
  SshFailureKind.notConnected => l10n.remoteServerFilesDisconnected,
  SshFailureKind.connectionLost => l10n.remoteTerminalConnectionLost,
  SshFailureKind.unsupported => l10n.remoteTerminalUnsupported,
  SshFailureKind.ptyRefused => l10n.remoteTerminalPtyRefused,
  SshFailureKind.other => failure.detail ?? l10n.remoteTerminalFailed,
};

class _Message extends StatelessWidget {
  const _Message({required this.title, this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 8), TextButton(onPressed: onAction, child: Text(action!))],
        ],
      ),
    );
  }
}
