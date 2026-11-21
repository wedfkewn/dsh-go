// 主机信息: what this host actually is, read from the host itself. Everything
// here is read-only — one `uname`-style probe over the shared SSH session plus
// the connection facts the app already holds (address, fingerprint, ownership,
// which file/terminal features the server offered). No DSH needed, so the page
// also works when the engine is not running.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/ssh/host_facts.dart';
import '../../remote/link_status.dart';
import '../../remote/ssh/ssh_link.dart';
import '../../state/hosts_state.dart';
import '../../state/ssh_session_state.dart';
import '../settings/settings_widgets.dart';
import '../../ui/session/workspace_files.dart' show formatBytes;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'ssh_ownership.dart';

class HostInfoPage extends ConsumerStatefulWidget {
  const HostInfoPage({super.key, required this.host, this.link});

  final HostRef host;

  /// The connection the workbench already holds, when there is one. Passed in
  /// rather than watched: watching `hostLinkProvider` would create a link (and
  /// with it a managed DSH start) just to read three facts off it.
  final HostLink? link;

  static Route<void> route(HostRef host, {HostLink? link}) =>
      MaterialPageRoute<void>(builder: (_) => HostInfoPage(host: host, link: link));

  @override
  ConsumerState<HostInfoPage> createState() => _HostInfoPageState();
}

class _HostInfoPageState extends ConsumerState<HostInfoPage> {
  HostFacts? _facts;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // After the first build: the page watches the shared session service there,
    // which is what keeps it alive while the page is open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = ref.read(sshSessionServiceProvider(widget.host));
      if (service == null) throw StateError('no ssh host');
      final facts = await readHostFacts(await service.acquire());
      if (!mounted) return;
      setState(() {
        _facts = facts;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = context.l10n.remoteHostInfoRetryHint;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final config = ref.watch(hostsProvider.select((s) => s.sshById(widget.host.id)));
    // Watched, not read: the page keeps the shared SSH session alive while it
    // is open, and closing the page closes its keepalive instead of leaking a
    // probe connection.
    ref.watch(sshSessionServiceProvider(widget.host));
    final link = widget.link;
    final facts = _facts;
    return AppPage.list(
      title: l10n.remoteHostInfoTitle,
      subtitle: Text(config?.name ?? l10n.commonRemoteHost, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: l10n.commonRetry,
          onPressed: _loading ? null : () => unawaited(_load()),
          icon: const Icon(AppIcons.restart),
        ),
      ],
      children: [
        SettingsSection(
          title: l10n.remoteHostInfoConnection,
          children: [
            _InfoTile(icon: AppIcons.remoteHost, title: l10n.remoteHostInfoAddress, value: _address(config)),
            _InfoTile(icon: AppIcons.lock, title: l10n.remoteHostInfoAuth, value: _auth(l10n, config)),
            _InfoTile(
              icon: AppIcons.fingerprint,
              title: l10n.remoteHostInfoFingerprint,
              value: _fingerprint(config),
            ),
            _InfoTile(
              icon: AppIcons.workspace,
              title: l10n.remoteHostInfoOwnership,
              value: link is SshHostLink
                  ? sshOwnershipLabel(context, config, ownership: link.ownership) ?? _ownershipFallback(l10n, config)
                  : _ownershipFallback(l10n, config),
            ),
            _InfoTile(
              icon: AppIcons.terminal,
              title: l10n.remoteHostInfoFeatures,
              value: _features(l10n, link),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.remoteHostInfoSystem,
          footer: _loading
              ? null
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    l10n.remoteHostInfoReadOnly,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
                  ),
                ),
          children: [
            if (_loading)
              SettingsTile(
                icon: AppIcons.restart,
                title: l10n.remoteHostInfoReading,
                chevron: false,
                trailing: const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_error case final error?)
              SettingsTile(
                icon: AppIcons.error,
                title: l10n.remoteHostInfoFailed,
                subtitle: error,
                chevron: false,
                onTap: _load,
              )
            else ...[
              if (facts?.os case final os?)
                _InfoTile(icon: AppIcons.computer, title: l10n.remoteHostInfoOs, value: os),
              if (facts?.kernel case final kernel?)
                _InfoTile(icon: AppIcons.code, title: l10n.remoteHostInfoKernel, value: kernel),
              if (facts?.arch case final arch?)
                _InfoTile(icon: AppIcons.engine, title: l10n.remoteHostInfoArch, value: arch),
              if (facts?.hostname case final hostname?)
                _InfoTile(icon: AppIcons.remoteHost, title: l10n.remoteHostInfoHostname, value: hostname),
              if (facts?.cpus case final cpus?)
                _InfoTile(icon: AppIcons.engine, title: l10n.remoteHostInfoCpus, value: '$cpus'),
              if (facts?.memoryBytes case final memory?)
                _InfoTile(icon: AppIcons.engine, title: l10n.remoteHostInfoMemory, value: formatBytes(memory)),
              if (facts?.load case final load?)
                _InfoTile(icon: AppIcons.sessionDetails, title: l10n.remoteHostInfoLoad, value: load),
              if (facts?.uptime case final uptime?)
                _InfoTile(icon: AppIcons.time, title: l10n.remoteHostInfoUptime, value: _duration(uptime)),
              if (facts?.diskTotalBytes case final total?)
                _InfoTile(
                  icon: AppIcons.chart,
                  title: l10n.remoteHostInfoDisk,
                  value: '${formatBytes(total - (facts!.diskFreeBytes ?? 0))} / ${formatBytes(total)}',
                ),
              if (facts != null && !facts.any)
                SettingsTile(
                  icon: AppIcons.error,
                  title: l10n.remoteHostInfoFailed,
                  chevron: false,
                  onTap: _load,
                ),
            ],
          ],
        ),
        SettingsSection(
          title: l10n.remoteHostInfoLimits,
          children: [
            for (final line in _limits(l10n)) SettingsTile(title: line, chevron: false),
          ],
        ),
      ],
    );
  }

  List<String> _limits(L10n l10n) => [
    l10n.remoteHostInfoLimitRecursive,
    l10n.remoteHostInfoLimitBatchDownload,
    l10n.remoteHostInfoLimitHeic,
    l10n.remoteHostInfoLimitSearch,
    l10n.remoteHostInfoLimitSymlink,
  ];

  String _address(SshHostConfig? config) {
    if (config == null) return '—';
    final port = config.port == 22 ? '' : ':${config.port}';
    return '${config.user}@${config.host}$port';
  }

  String _auth(L10n l10n, SshHostConfig? config) {
    if (config == null) return '—';
    return switch (config.auth) {
      SshAuthMethod.password => l10n.remoteHostInfoAuthPassword,
      SshAuthMethod.privateKey => l10n.remoteHostInfoAuthKey,
    };
  }

  String _fingerprint(SshHostConfig? config) {
    final value = config?.hostKeyFingerprint;
    if (value == null || value.isEmpty) return '—';
    // Enough to compare against `ssh-keygen -lf`, not a wall of hex.
    final head = value.length <= 24 ? value : '${value.substring(0, 24)}…';
    return config?.hostKeyType == null ? head : '${config!.hostKeyType} · $head';
  }

  String _ownershipFallback(L10n l10n, SshHostConfig? config) => config?.dshMode == SshDshMode.attachOnly
      ? l10n.remoteOwnershipAttach
      : l10n.remoteOwnershipManaged;

  String _features(L10n l10n, HostLink? link) {
    if (link is! SshHostLink) return l10n.remoteHostInfoFeaturesUnknown;
    final parts = [
      if (link.hasSftp) l10n.remoteHostInfoFeatureSftp,
      if (link.hasPty) l10n.remoteHostInfoFeaturePty,
    ];
    return parts.isEmpty ? l10n.remoteHostInfoFeatureNone : parts.join(' · ');
  }

  String _duration(Duration uptime) {
    if (uptime.inDays >= 1) return '${uptime.inDays} d ${uptime.inHours % 24} h';
    if (uptime.inHours >= 1) return '${uptime.inHours} h ${uptime.inMinutes % 60} min';
    return '${uptime.inMinutes} min';
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.icon, required this.title, required this.value});

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    // The value side of a settings row is not flexible: a real fingerprint
    // (`ssh-ed25519 · SHA256:` + 43 chars) overflows the row on a phone and at
    // larger Dynamic Type. Let it take the space that is left and ellipsize.
    return SettingsTile(
      icon: icon,
      title: title,
      value: Flexible(
        child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end),
      ),
      chevron: false,
      tinted: false,
    );
  }
}
