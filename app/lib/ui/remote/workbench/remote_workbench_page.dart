// 远程工作台: one connected server's way in — 主机名、SSH/DSH 状态、当前工作区
// 和当前模型 on top, then the eight places you go from here (任务书 §8).
//
// Everything reads the active host's real providers; nothing here invents a
// state. Entries whose core interface has not landed yet stay visible but
// disabled, with the reason on the card, so the page never pretends a feature
// works.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../remote/ssh/ssh_link.dart';
import '../../../state/connection_state.dart';
import '../../../state/hosts_state.dart';
import '../../../state/models_state.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workspaces_state.dart';
import '../../chat/model_sheet.dart' show modelShortName;
import '../../common/overview_card.dart';
import '../../common/status_chip.dart';
import '../../common/tile_grid.dart';
import '../../plugins/plugins_screen.dart';
import '../../providers/providers_page.dart';
import '../host_info_page.dart';
import '../../shell/page_frame.dart';
import '../../shell/session_search_page.dart' show showSessionSearch;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../../workspace/workspaces_page.dart';
import '../host_status.dart';
import '../host_switcher.dart' show showHostSheet;
import '../link_progress.dart' show LinkErrorBox;
import '../remote_screen.dart';
import '../server_files_page.dart';
import '../ssh_terminal_page.dart';
import '../ssh_host_form.dart';
import '../ssh_ownership.dart';

/// Which SSH-only surfaces the core already exposes. They stay false until
/// `SshTransport.openPty` / `openSftp` and the host-info call land; the cards
/// then say so instead of opening an empty page. Flip here, once, when the
/// contract is in.
const kRemoteHostInfoReady = true;

class RemoteWorkbenchPage extends ConsumerWidget {
  const RemoteWorkbenchPage({super.key, required this.host});

  final HostRef host;

  static Route<void> route(HostRef host) => MaterialPageRoute<void>(builder: (_) => RemoteWorkbenchPage(host: host));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(hostLinkStatusProvider(host)).value ?? HostLinkStatus.idle;
    final connected = status.isConnected;
    final config = host.kind == HostKind.ssh ? ref.watch(hostsProvider).sshById(host.id) : null;
    final hasChats = ref.watch(sessionsProvider).value?.isNotEmpty ?? true;
    final link = ref.watch(hostLinkProvider(host));
    final canSftp = connected && link is SshHostLink && link.hasSftp;
    final canPty = connected && link is SshHostLink && link.hasPty;
    // Switching hosts from the header must not leave this page on the old
    // server: close it and let the new host's own screen take over.
    ref.listen(activeHostProvider, (previous, next) {
      if (previous != next && next != host && context.mounted) Navigator.of(context).maybePop();
    });
    void push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

    return AppPage.list(
      title: l10n.remoteWorkbench,
      subtitle: Text(l10n.remoteWorkbenchIntro),
      children: [
        _WorkbenchHeader(host: host, config: config, status: status),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Semantics(header: true, child: Text(l10n.remoteWorkbenchEntries, style: _groupStyle(context))),
        ),
        TileGrid(
          children: [
            FeatureCard(
              icon: AppIcons.chat,
              title: l10n.remoteWorkbenchAiChat,
              subtitle: connected
                  ? (hasChats ? l10n.remoteWorkbenchAiChatHint : l10n.remoteWorkbenchNoChats)
                  : l10n.remoteWorkbenchNeedsConnection,
              tint: 0,
              enabled: connected,
              // With a conversation already open, back to the chat; otherwise
              // pick a real remote conversation first, so this never lands on
              // an empty local screen.
              onTap: connected
                  ? () async {
                      if (ref.read(currentSessionProvider) == null) {
                        final sessionId = await showSessionSearch(context);
                        if (!context.mounted || sessionId == null) return;
                        ref.read(currentSessionProvider.notifier).select(sessionId);
                      }
                      if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
                    }
                  : null,
            ),
            FeatureCard(
              icon: AppIcons.workspace,
              title: l10n.remoteWorkbenchWorkspaces,
              subtitle: connected ? l10n.remoteWorkbenchWorkspacesHint : l10n.remoteWorkbenchNeedsConnection,
              tint: 1,
              enabled: connected,
              onTap: connected ? () => push(const WorkspacesPage()) : null,
            ),
            FeatureCard(
              icon: AppIcons.files,
              title: l10n.remoteWorkbenchServerFiles,
              subtitle: canSftp
                  ? l10n.remoteWorkbenchServerFilesHint
                  : connected
                  ? l10n.remoteServerFilesUnsupported
                  : l10n.remoteWorkbenchNeedsConnection,
              tint: 2,
              enabled: canSftp,
              onTap: canSftp ? () => push(ServerFilesPage(host: host)) : null,
            ),
            FeatureCard(
              icon: AppIcons.terminal,
              title: l10n.remoteWorkbenchTerminal,
              subtitle: canPty
                  ? l10n.remoteWorkbenchTerminalHint
                  : connected
                  ? l10n.remoteTerminalUnsupported
                  : l10n.remoteWorkbenchNeedsConnection,
              tint: 3,
              enabled: canPty,
              onTap: canPty ? () => push(SshTerminalPage(host: host)) : null,
            ),
            FeatureCard(
              icon: AppIcons.model,
              title: l10n.remoteWorkbenchModels,
              subtitle: connected ? l10n.remoteWorkbenchModelsHint : l10n.remoteWorkbenchNeedsConnection,
              tint: 4,
              enabled: connected,
              onTap: connected ? () => push(const ProvidersPage()) : null,
            ),
            FeatureCard(
              icon: AppIcons.plugin,
              title: l10n.remoteWorkbenchPlugins,
              subtitle: connected ? l10n.remoteWorkbenchPluginsHint : l10n.remoteWorkbenchNeedsConnection,
              tint: 5,
              enabled: connected,
              onTap: connected ? () => push(const PluginsScreen()) : null,
            ),
            FeatureCard(
              icon: AppIcons.info,
              title: l10n.remoteWorkbenchHostInfo,
              subtitle: kRemoteHostInfoReady ? l10n.remoteWorkbenchHostInfoHint : l10n.remoteWorkbenchSoonHostInfo,
              tint: 6,
              enabled: connected && kRemoteHostInfoReady,
              onTap: connected && kRemoteHostInfoReady
                  ? () => Navigator.of(context).push(HostInfoPage.route(host, link: ref.read(hostLinkProvider(host))))
                  : null,
            ),
            FeatureCard(
              icon: AppIcons.configure,
              title: l10n.remoteWorkbenchSettings,
              subtitle: l10n.remoteWorkbenchSettingsHint,
              tint: 7,
              enabled: config != null || host.kind == HostKind.relay,
              onTap: config != null
                  ? () => push(SshHostFormPage(existing: config))
                  : host.kind == HostKind.relay
                  ? () => push(const RemoteScreen())
                  : null,
            ),
          ],
        ),
        if (!connected)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.remoteWorkbenchNeedsConnection,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
                  ),
                ),
                TextButton(
                  onPressed: () => ref.read(remoteConnectionProvider(host).notifier).retry(),
                  child: Text(l10n.commonRetry),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The page's group caption: the same 24/8 rhythm as 全部功能.
TextStyle? _groupStyle(BuildContext context) =>
    Theme.of(context).textTheme.labelLarge
        ?.copyWith(color: DshColors.of(context).textTertiary, fontWeight: FontWeight.w600);

class _WorkbenchHeader extends ConsumerWidget {
  const _WorkbenchHeader({required this.host, required this.config, required this.status});

  final HostRef host;
  final SshHostConfig? config;
  final HostLinkStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final name = ref.watch(hostNameProvider(host)) ?? l10n.commonRemoteHost;
    final view = HostStatusView.ofLink(status);
    final workspace = ref.watch(selectedWorkspaceProvider);
    final catalog = ref.watch(currentModelCatalogProvider);
    final selection = catalog?.defaultSelection;
    final link = ref.watch(hostLinkProvider(host));
    final ownership = sshOwnershipLabel(context, config, ownership: link is SshHostLink ? link.ownership : null);
    final connected = status.isConnected;
    final sshState = status.phase == HostLinkPhase.connected
        ? l10n.remoteConnected
        : status.phase == HostLinkPhase.failed
        ? l10n.commonConnectionFailed
        : view.label;
    final dshState = connected ? l10n.remoteWorkbenchReady : l10n.remoteWorkbenchNotReady;
    void push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    final error = status.error;
    // The one follow-up that can actually fix this failure: sign in again,
    // edit the host (a non-retryable SSH error), or retry the link.
    (String, VoidCallback)? errorAction() {
      if (error == null) return null;
      if (error.kind == HostLinkErrorKind.notLoggedIn) {
        return (l10n.remoteSignInAgain, () => push(const RemoteScreen()));
      }
      if (config != null && !error.retryable) {
        return (l10n.remoteHostSettings, () => push(SshHostFormPage(existing: config)));
      }
      return (l10n.commonRetry, () => ref.read(remoteConnectionProvider(host).notifier).retry());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OverviewCard(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          leading: OverviewGlyph(hostKindIcon(host.kind), tint: hostKindTint(host.kind)),
          title: Text(name),
          subtitle: Row(
            children: [
              AnimatedStatusDot(tone: view.tone, size: 7),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  [
                    '${l10n.remoteWorkbenchSsh} $sshState',
                    '${l10n.remoteWorkbenchDsh} $dshState',
                    ?ownership,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          trailing: TextButton(
            onPressed: () => showHostSheet(context, onManage: () => push(const RemoteScreen())),
            child: Text(l10n.remoteWorkbenchSwitch),
          ),
          footer: Row(
            children: [
              Expanded(
                child: _Meta(
                  label: l10n.remoteWorkbenchCurrentWorkspace,
                  value: workspace == null ? l10n.remoteWorkbenchAllChats : workspaceTitle(workspace),
                  onTap: connected ? () => push(const WorkspacesPage()) : null,
                ),
              ),
              Container(width: 0.5, height: 30, color: Theme.of(context).dividerColor.withValues(alpha: 0.5)),
              Expanded(
                child: _Meta(
                  label: l10n.remoteWorkbenchCurrentModel,
                  value: catalog == null ? l10n.engineProvidersNotConnected : modelShortName(selection, catalog),
                  onTap: connected ? () => push(const ProvidersPage()) : null,
                ),
              ),
            ],
          ),
        ),
        if (status.phase == HostLinkPhase.failed && error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: LinkErrorBox(error: error, action: errorAction()),
          ),
        if (host.kind == HostKind.relay && !connected)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
            child: Text(
              l10n.remoteWorkbenchNeedsConnection,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
            ),
          ),
      ],
    );
  }
}

/// One footer field: a caption over its value, both left-aligned; the whole
/// field is the tap target.
class _Meta extends StatelessWidget {
  const _Meta({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(color: onTap == null ? colors.textTertiary : null),
          ),
        ],
      ),
    );
    if (onTap == null) return body;
    return Semantics(
      button: true,
      label: '$label: $value',
      child: InkWell(onTap: onTap, child: body),
    );
  }
}
