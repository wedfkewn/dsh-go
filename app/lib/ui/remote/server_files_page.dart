// 服务器文件: the whole SSH server's disk over the shared SSH session layer
// (`sftpProvider`), independent of DSH. The page only renders that state and
// asks for explicit operations; connection, listing, transfers, cancellation
// and reconnect semantics live in `SftpController`.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../../state/attachments.dart';
import '../../state/compose_inbox.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/sftp_favorites_state.dart';
import '../../state/sftp_state.dart';
import '../../state/workspaces_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/breadcrumb_row.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../common/sheet_title_bar.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../workspace/text_prompt.dart';
import 'sftp_failure_text.dart';
import 'sftp_temp_dir.dart';
import 'server_file_preview_page.dart';
import 'ssh_terminal_page.dart';

class ServerFilesPage extends ConsumerStatefulWidget {
  const ServerFilesPage({super.key, required this.host});

  final HostRef host;

  static Route<void> route(HostRef host) => MaterialPageRoute<void>(builder: (_) => ServerFilesPage(host: host));

  @override
  ConsumerState<ServerFilesPage> createState() => _ServerFilesPageState();
}

class _ServerFilesPageState extends ConsumerState<ServerFilesPage> {
  bool _hidden = false;

  /// Selection mode for batch operations: the absolute paths ticked.
  bool _selecting = false;
  final _selected = <String>{};

  /// Biggest file handed to the chat composer; larger ones are refused here
  /// instead of being downloaded and then rejected by the attachment budget.
  static const _maxAttachBytes = 64 * 1024 * 1024;

  /// Search over the current folder tree; results live in the controller state.
  final _search = TextEditingController();
  bool _searchOpen = false;

  SftpController get _sftp => ref.read(sftpProvider(widget.host).notifier);

  /// The page belongs to one host, but 工作区 and the composer draft belong to
  /// whatever host is selected now. Anything that writes through those must
  /// first prove the host did not move under us.
  bool get _hostStillActive => ref.read(activeHostProvider) == widget.host;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_sftp.connect());
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openFolder(SftpEntry entry) => _sftp.open(entry.path);

  Future<void> _menu(SftpEntry entry) async {
    final l10n = context.l10n;
    final favorite = ref.read(sftpFavoritesProvider(widget.host)).paths.contains(entry.path);
    final action = await showAppSheet<String>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(sheet).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.path,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.mono(size: 12, color: DshColors.of(sheet).textTertiary),
                  ),
                ],
              ),
            ),
            SheetGroup(
              children: [
                if (entry.isDirectory)
                  SettingsTile(
                    icon: favorite ? AppIcons.favoriteActive : AppIcons.favorite,
                    tinted: false,
                    title: favorite ? l10n.remoteServerFilesFavoriteRemove : l10n.remoteServerFilesFavoriteAdd,
                    chevron: false,
                    onTap: () => Navigator.pop(sheet, 'favorite'),
                  ),
                if (entry.isDirectory)
                  SettingsTile(
                    icon: AppIcons.workspace,
                    tinted: false,
                    title: context.l10n.remoteServerFilesAddToWorkspace,
                    chevron: false,
                    onTap: () => Navigator.pop(sheet, 'workspace'),
                  ),
                if (!entry.isDirectory)
                  SettingsTile(
                    icon: AppIcons.add,
                    tinted: false,
                    title: context.l10n.remoteServerFilesAttach,
                    chevron: false,
                    onTap: () => Navigator.pop(sheet, 'attach'),
                  ),
                if (!entry.isDirectory)
                  SettingsTile(
                    icon: AppIcons.preview,
                    tinted: false,
                    title: context.l10n.remoteServerFilesPreview,
                    chevron: false,
                    onTap: () => Navigator.pop(sheet, 'preview'),
                  ),
                if (!entry.isDirectory)
                  SettingsTile(
                    icon: AppIcons.download,
                    tinted: false,
                    title: context.l10n.remoteServerFilesDownload,
                    chevron: false,
                    onTap: () => Navigator.pop(sheet, 'download'),
                  ),
                if (!entry.isDirectory)
                  SettingsTile(
                    icon: AppIcons.copy,
                    tinted: false,
                    title: context.l10n.remoteServerFilesCopyTo,
                    chevron: false,
                    onTap: () => Navigator.pop(sheet, 'copy'),
                  ),
                SettingsTile(
                  icon: AppIcons.moveToFolder,
                  tinted: false,
                  title: context.l10n.remoteServerFilesMoveTo,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, 'move'),
                ),
                SettingsTile(
                  icon: AppIcons.rename,
                  tinted: false,
                  title: context.l10n.remoteServerFilesRename,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, 'rename'),
                ),
                SettingsTile(
                  icon: AppIcons.permissions,
                  tinted: false,
                  title: context.l10n.remoteServerFilesPermissions,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, 'chmod'),
                ),
                SettingsTile(
                  icon: AppIcons.delete,
                  tinted: false,
                  danger: true,
                  title: context.l10n.remoteServerFilesDelete,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, 'delete'),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'favorite':
        await ref.read(sftpFavoritesProvider(widget.host).notifier).toggle(entry.path);
        if (mounted) {
          showBriefNotice(
            context,
            favorite ? l10n.remoteServerFilesFavoriteRemoved : l10n.remoteServerFilesFavoriteAdded(entry.path),
          );
        }
      case 'workspace':
        await _addToWorkspace(entry.path);
      case 'attach':
        await _attachToChat(entry);
      case 'copy':
        await _copyTo(entry);
      case 'move':
        await _moveTo(entry);
      case 'preview':
        await Navigator.of(context).push(ServerFilePreviewPage.route(host: widget.host, entry: entry));
      case 'download':
        await _download(entry);
      case 'rename':
        await _rename(entry);
      case 'chmod':
        await _chmod(entry);
      case 'delete':
        await _delete(entry);
    }
  }

  Future<void> _rename(SftpEntry entry) async {
    final l10n = context.l10n;
    final next = await showTextPrompt(
      context,
      title: l10n.remoteServerFilesRename,
      initial: entry.name,
      hint: l10n.commonName,
      validate: (text) => text.trim().isEmpty || text.contains('/') ? l10n.remoteServerFilesNameInvalid : null,
    );
    if (next == null || next.trim() == entry.name || !mounted) return;
    await _guard(() => _sftp.rename(entry.path, next.trim()));
  }

  Future<void> _chmod(SftpEntry entry) async {
    final l10n = context.l10n;
    final current = entry.permissionBits?.toRadixString(8).padLeft(3, '0') ?? '';
    final text = await showTextPrompt(
      context,
      title: l10n.remoteServerFilesPermissionsTitle(entry.name),
      initial: current,
      hint: '644',
      caption: '${l10n.remoteServerFilesPermissionsHint}\n${l10n.remoteServerFilesPermissionsWarning}',
      keyboardType: TextInputType.number,
      validate: (value) =>
          RegExp(r'^[0-7]{3,4}$').hasMatch(value.trim()) ? null : l10n.remoteServerFilesPermissionsInvalid,
    );
    if (text == null || !mounted) return;
    await _guard(() => _sftp.chmod(entry.path, int.parse(text.trim(), radix: 8)));
  }

  Future<void> _delete(SftpEntry entry) async {
    final l10n = context.l10n;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.remoteServerFilesDeleteTitle(entry.name)),
        content: Text('${l10n.remoteServerFilesDeleteBody}\n\n${entry.path}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _guard(() => _sftp.remove(entry.path, directory: entry.isDirectory));
  }

  Future<void> _toggleFavorite() async {
    final l10n = context.l10n;
    final path = ref.read(sftpProvider(widget.host)).path;
    final favorites = ref.read(sftpFavoritesProvider(widget.host).notifier);
    final adding = !favorites.contains(path);
    await favorites.toggle(path);
    if (mounted) {
      showBriefNotice(
        context,
        adding ? l10n.remoteServerFilesFavoriteAdded(path) : l10n.remoteServerFilesFavoriteRemoved,
      );
    }
  }

  Future<void> _showFavorites() async {
    final l10n = context.l10n;
    final state = ref.read(sftpFavoritesProvider(widget.host));
    final picked = await showAppSheet<String>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: SheetTitleBar(l10n.remoteServerFilesFavorites),
            ),
            if (state.paths.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Text(l10n.remoteServerFilesFavoritesEmpty, style: Theme.of(sheet).textTheme.bodyMedium),
              ),
            if (state.paths.isNotEmpty)
              SheetGroup(
                children: [
                  for (final path in state.paths)
                    SettingsTile(
                      icon: AppIcons.favoriteActive,
                      tinted: false,
                      title: path.split('/').last.isEmpty ? path : path.split('/').last,
                      subtitle: path,
                      onTap: () => Navigator.pop(sheet, path),
                      trailing: IconButton(
                        tooltip: l10n.remoteServerFilesFavoriteRemove,
                        icon: Icon(AppIcons.remove, color: DshColors.of(sheet).textTertiary),
                        onPressed: () async {
                          await ref.read(sftpFavoritesProvider(widget.host).notifier).remove(path);
                          if (sheet.mounted) Navigator.pop(sheet);
                        },
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (picked != null && mounted) await _sftp.open(picked);
  }

  /// 加入工作区 for the current directory: the path goes to the DSH instance on
  /// this host, so it needs that connection — a plain SSH session is not enough.
  Future<void> _addToWorkspace(String path) async {
    final l10n = context.l10n;
    if (!_hostStillActive) {
      showBriefNotice(context, l10n.remoteServerFilesHostChanged);
      return;
    }
    try {
      await ref.read(workspacesProvider.notifier).add(path);
      if (mounted) showBriefNotice(context, l10n.remoteServerFilesWorkspaceAdded(path));
    } on Object {
      if (mounted) showBriefNotice(context, l10n.remoteServerFilesWorkspaceFailed);
    }
  }

  /// 加入对话附件: download to the cache, then leave the bytes in the new-chat
  /// draft. The composer owns them from there; nothing is sent.
  Future<void> _attachToChat(SftpEntry entry) async {
    final l10n = context.l10n;
    if (!_hostStillActive) {
      showBriefNotice(context, l10n.remoteServerFilesHostChanged);
      return;
    }
    final size = entry.size;
    if (size != null && size > _maxAttachBytes) {
      showBriefNotice(context, l10n.remoteServerFilesAttachTooLarge);
      return;
    }
    final local = await sftpTempPath(widget.host, entry.name);
    final running = _sftp.download(remotePath: entry.path, localPath: local);
    _showTransfers();
    await running;
    if (!mounted) return;
    // This download's own row, not any file that happens to share the name.
    final transfer = _transferFor(local);
    if (transfer == null || transfer.status != SftpTransferStatus.done) return;
    // The download may have taken a while: the person can have switched hosts
    // meanwhile, and the draft belongs to the one selected now.
    if (!_hostStillActive) {
      await File(local).delete().catchError((_) => File(local));
      if (mounted) showBriefNotice(context, l10n.remoteServerFilesHostChanged);
      return;
    }
    try {
      // The listed size can be stale (or missing); the real file decides
      // whether it can be held as an attachment.
      final actual = await File(local).length();
      if (actual > _maxAttachBytes) {
        if (mounted) showBriefNotice(context, l10n.remoteServerFilesAttachTooLarge);
        return;
      }
      final bytes = await File(local).readAsBytes();
      if (!mounted) return;
      if (!_hostStillActive) {
        showBriefNotice(context, l10n.remoteServerFilesHostChanged);
        return;
      }
      ref.read(composeInboxProvider.notifier).push(
        ComposeRequest(attachments: [DraftAttachment.sniff(entry.name, bytes)]),
      );
      _sftp.clearFinished();
      Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    } on Object {
      if (mounted) showBriefNotice(context, l10n.remoteServerFilesAttachFailed);
    }
  }

  Future<void> _batchDelete() async {
    final l10n = context.l10n;
    final entries = [
      for (final entry in ref.read(sftpProvider(widget.host)).entries)
        if (_selected.contains(entry.path)) entry,
    ];
    if (entries.isEmpty) return;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.remoteServerFilesBatchDeleteTitle(entries.length)),
        content: SingleChildScrollView(
          child: Text(
            '${l10n.remoteServerFilesBatchDeleteBody}\n\n'
            '${entries.map((e) => e.path).join('\n')}',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    // One by one, stopping at the first refusal: the rest are untouched and
    // the person learns exactly which entry the server rejected.
    for (final entry in entries) {
      try {
        await _sftp.remove(entry.path, directory: entry.isDirectory);
      } on SftpFailure catch (error) {
        if (mounted) {
          showBriefNotice(context, l10n.remoteServerFilesBatchFailed(entry.name, sftpFailureText(l10n, error)));
        }
        return;
      } on Object {
        if (mounted) showBriefNotice(context, l10n.remoteServerFilesBatchFailed(entry.name, l10n.remoteServerFilesOperationFailed));
        return;
      }
    }
  }

  /// Copies or moves every selected entry into one folder, one at a time;
  /// the first refusal stops the batch. Copying a folder is refused by the
  /// state layer, so folders are skipped here and counted.
  Future<void> _batchTransfer({required bool copy}) async {
    final l10n = context.l10n;
    final entries = [
      for (final entry in ref.read(sftpProvider(widget.host)).entries)
        if (_selected.contains(entry.path)) entry,
    ];
    if (entries.isEmpty) return;
    final current = ref.read(sftpProvider(widget.host)).path;
    final directory = await showTextPrompt(
      context,
      title: copy ? l10n.remoteServerFilesCopyTo : l10n.remoteServerFilesMoveTo,
      initial: current,
      hint: l10n.remoteServerFilesDestHint,
      validate: (text) => text.trim().startsWith('/') ? null : l10n.remoteServerFilesDestInvalid,
    );
    if (directory == null || !mounted) return;
    final destination = directory.trim();
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          copy
              ? l10n.remoteServerFilesConfirmCopyTitle(destination)
              : l10n.remoteServerFilesConfirmMoveTitle(destination),
        ),
        content: Text(copy ? l10n.remoteServerFilesConfirmCopyBody : l10n.remoteServerFilesConfirmMoveBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(copy ? l10n.remoteServerFilesCopyTo : l10n.remoteServerFilesMoveTo)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    for (final entry in entries) {
      if (copy && entry.isDirectory) continue;
      final target = _join(destination, entry.name);
      if (target == entry.path) continue;
      try {
        if (copy) {
          await _sftp.copy(from: entry.path, to: target);
        } else {
          await _sftp.move(from: entry.path, to: target);
        }
      } on SftpFailure catch (error) {
        if (mounted) {
          showBriefNotice(context, l10n.remoteServerFilesBatchFailed(entry.name, sftpFailureText(l10n, error)));
        }
        return;
      } on Object {
        if (mounted) {
          showBriefNotice(
            context,
            l10n.remoteServerFilesBatchFailed(entry.name, l10n.remoteServerFilesOperationFailed),
          );
        }
        return;
      }
    }
    if (mounted) showBriefNotice(context, copy ? l10n.remoteServerFilesCopied : l10n.remoteServerFilesMoved);
  }

  /// The transfer row for [localPath]. Paths are unique per download, so this
  /// identifies exactly the transfer that wrote the file.
  SftpTransfer? _transferFor(String localPath) {
    for (final transfer in ref.read(sftpProvider(widget.host)).transfers) {
      if (transfer.localPath == localPath && !transfer.upload) return transfer;
    }
    return null;
  }

  /// 溢出面板: everything that is not one of the four actions in the bar. A
  /// phone-width toolbar cannot hold eight icons without overflowing.
  Future<void> _pageMenu() async {
    final l10n = context.l10n;
    final action = await showAppSheet<String>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            SheetGroup(
              children: [
                SettingsTile(
                  icon: AppIcons.search,
                  tinted: false,
                  title: l10n.remoteServerFilesSearch,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, 'search'),
                ),
                SettingsTile(
                  icon: AppIcons.multiSelect,
                  tinted: false,
                  title: l10n.remoteServerFilesSelect,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, 'select'),
                ),
                SettingsTile(
                  icon: _hidden ? AppIcons.checkboxOn : AppIcons.hideSecret,
                  tinted: false,
                  title: l10n.remoteServerFilesHidden,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, 'hidden'),
                ),
                SettingsTile(
                  icon: AppIcons.newFolder,
                  tinted: false,
                  title: l10n.remoteServerFilesNewFolder,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, 'newFolder'),
                ),
                SettingsTile(
                  icon: AppIcons.uploadToHost,
                  tinted: false,
                  title: l10n.remoteServerFilesUpload,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, 'upload'),
                ),
                SettingsTile(
                  icon: AppIcons.bookmark,
                  tinted: false,
                  title: l10n.remoteServerFilesFavorites,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, 'favorites'),
                ),
                SettingsTile(
                  icon: AppIcons.terminal,
                  tinted: false,
                  title: l10n.remoteTerminalOpenHere,
                  chevron: false,
                  onTap: () => Navigator.pop(sheet, 'terminal'),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    final path = ref.read(sftpProvider(widget.host)).path;
    switch (action) {
      case 'search':
        _openSearch();
      case 'select':
        setState(() {
          _selecting = true;
          _selected.clear();
        });
      case 'hidden':
        setState(() => _hidden = !_hidden);
      case 'newFolder':
        await _newFolder();
      case 'upload':
        await _upload();
      case 'favorites':
        await _showFavorites();
      case 'terminal':
        await Navigator.of(context).push(SshTerminalPage.route(widget.host, initialDirectory: path));
    }
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    _sftp.clearSearch();
  }

  void _closeSearch() {
    _search.clear();
    _sftp.clearSearch();
    setState(() => _searchOpen = false);
  }

  Future<void> _runSearch() async {
    final query = _search.text.trim();
    if (query.isEmpty) {
      _sftp.clearSearch();
      return;
    }
    await _guard(() => _sftp.search(query, includeHidden: _hidden));
  }

  /// Asks for a destination folder, then copies or moves one entry there.
  /// Always confirmed: the target may already exist and is replaced.
  Future<void> _transferTo(SftpEntry entry, {required bool copy}) async {
    final l10n = context.l10n;
    final current = ref.read(sftpProvider(widget.host)).path;
    final directory = await showTextPrompt(
      context,
      title: copy ? l10n.remoteServerFilesCopyTo : l10n.remoteServerFilesMoveTo,
      initial: current,
      hint: l10n.remoteServerFilesDestHint,
      validate: (text) => text.trim().startsWith('/') ? null : l10n.remoteServerFilesDestInvalid,
    );
    if (directory == null || !mounted) return;
    final target = _join(directory.trim(), entry.name);
    if (target == entry.path) {
      showBriefNotice(context, l10n.remoteServerFilesSamePlace);
      return;
    }
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          copy
              ? l10n.remoteServerFilesConfirmCopyTitle(target)
              : l10n.remoteServerFilesConfirmMoveTitle(target),
        ),
        content: Text(copy ? l10n.remoteServerFilesConfirmCopyBody : l10n.remoteServerFilesConfirmMoveBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(copy ? l10n.remoteServerFilesCopyTo : l10n.remoteServerFilesMoveTo),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _guard(
      () => copy ? _sftp.copy(from: entry.path, to: target) : _sftp.move(from: entry.path, to: target),
    );
    if (mounted) showBriefNotice(context, copy ? l10n.remoteServerFilesCopied : l10n.remoteServerFilesMoved);
  }

  Future<void> _copyTo(SftpEntry entry) => _transferTo(entry, copy: true);

  Future<void> _moveTo(SftpEntry entry) => _transferTo(entry, copy: false);

  static String _join(String directory, String name) =>
      directory.endsWith('/') ? '$directory$name' : '$directory/$name';

  Future<void> _newFolder() async {
    final l10n = context.l10n;
    final name = await showTextPrompt(
      context,
      title: l10n.remoteServerFilesNewFolder,
      hint: l10n.remoteServerFilesNameHint,
      validate: (text) => text.trim().isEmpty || text.contains('/') ? l10n.remoteServerFilesNameInvalid : null,
    );
    if (name == null || !mounted) return;
    await _guard(() => _sftp.createDirectory(name.trim()));
  }

  Future<void> _upload() async {
    final l10n = context.l10n;
    final files = await FilePicker.pickFiles();
    final paths = [
      for (final file in files)
        if (file.path != null) file.path!,
    ];
    if (paths.isEmpty || !mounted) return;
    final state = ref.read(sftpProvider(widget.host));
    for (final path in paths) {
      if (!mounted) return;
      final name = path.split('/').last;
      if (state.entries.any((e) => e.name == name)) {
        final ok = await showAppDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(l10n.remoteServerFilesOverwriteUploadTitle(name)),
            content: Text('${l10n.remoteServerFilesOverwriteUploadBody}\n\n${state.path}/$name'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: DshColors.of(dialog).danger,
                  foregroundColor: DshColors.of(dialog).onDanger,
                ),
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(l10n.remoteServerFilesUpload),
              ),
            ],
          ),
        );
        if (ok != true) continue;
      }
      unawaited(_sftp.upload(localPath: path, remoteDir: state.path));
    }
    _showTransfers();
  }

  Future<void> _download(SftpEntry entry) async {
    final l10n = context.l10n;
    final local = await sftpTempPath(widget.host, entry.name);
    final running = _sftp.download(remotePath: entry.path, localPath: local);
    _showTransfers();
    await running;
    if (!mounted) return;
    final transfer = _transferFor(local);
    if (transfer == null || transfer.status != SftpTransferStatus.done) return;
    _sftp.clearFinished();
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(local, name: entry.name)],
        fileNameOverrides: [entry.name],
      ),
    );
    if (mounted) showBriefNotice(context, l10n.remoteServerFilesDownloaded(entry.name));
  }

  void _showTransfers() {
    unawaited(showAppSheet<void>(context, isScrollControlled: true, builder: (_) => _TransferSheet(host: widget.host)));
  }

  Future<void> _guard(Future<void> Function() body) async {
    if (!mounted) return;
    try {
      await body();
    } on SftpFailure catch (error) {
      if (mounted) showBriefNotice(context, sftpFailureText(context.l10n, error));
    } on Object {
      if (mounted) showBriefNotice(context, context.l10n.remoteServerFilesOperationFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(sftpProvider(widget.host));
    final name = ref.watch(hostNameProvider(widget.host)) ?? l10n.commonRemoteHost;
    final visible = state.entries.where((e) => _hidden || !e.name.startsWith('.')).toList();
    final running = state.transfers.where((t) => t.running).length;
    final favorite = ref.watch(
      sftpFavoritesProvider(widget.host).select((favorites) => favorites.paths.contains(state.path)),
    );
    return AppPage.list(
      title: l10n.remoteServerFilesTitle,
      subtitle: Text('$name · ${state.path}', maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: _selecting
          ? [
              IconButton(
                tooltip: l10n.commonDone,
                onPressed: () => setState(() {
                  _selecting = false;
                  _selected.clear();
                }),
                icon: const Icon(AppIcons.done),
              ),
            ]
          : [
              IconButton(
                tooltip: l10n.remoteServerFilesSearch,
                onPressed: state.ready ? _openSearch : null,
                icon: const Icon(AppIcons.search),
              ),
              IconButton(
                tooltip: favorite ? l10n.remoteServerFilesFavoriteRemove : l10n.remoteServerFilesFavoriteAdd,
                onPressed: state.ready ? _toggleFavorite : null,
                icon: Icon(favorite ? AppIcons.favoriteActive : AppIcons.favorite),
              ),
              IconButton(
                tooltip: l10n.remoteServerFilesTransfers(running),
                onPressed: () => _showTransfers(),
                icon: Badge(
                  isLabelVisible: running > 0,
                  label: Text('$running'),
                  child: const Icon(AppIcons.download),
                ),
              ),
              IconButton(
                tooltip: l10n.commonMore,
                onPressed: state.ready ? () => unawaited(_pageMenu()) : null,
                icon: const Icon(AppIcons.more),
              ),
            ],
      children: [
        BreadcrumbRow(crumbs: _crumbs(l10n, state.path), onTap: (path) => unawaited(_sftp.open(path))),
        if (_searchOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _search,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: l10n.remoteServerFilesSearchHint,
                prefixIcon: const Icon(AppIcons.search),
                suffixIcon: IconButton(
                  tooltip: l10n.commonClose,
                  icon: const Icon(AppIcons.close),
                  onPressed: _closeSearch,
                ),
              ),
              onSubmitted: (_) => unawaited(_runSearch()),
            ),
          ),
        if (_selecting)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                child: Row(
                  children: [
                    Expanded(child: Text(l10n.remoteServerFilesSelected(_selected.length))),
                    TextButton(
                      onPressed: () => setState(() {
                        if (_selected.length == visible.length) {
                          _selected.clear();
                        } else {
                          _selected.addAll(visible.map((e) => e.path));
                        }
                      }),
                      child: Text(l10n.remoteServerFilesSelectAll),
                    ),
                    TextButton(
                      onPressed: _selected.isEmpty || !visible.any((e) => _selected.contains(e.path) && !e.isDirectory)
                          ? null
                          : () => unawaited(_batchTransfer(copy: true)),
                      child: Text(l10n.remoteServerFilesCopyTo),
                    ),
                    TextButton(
                      onPressed: _selected.isEmpty ? null : () => unawaited(_batchTransfer(copy: false)),
                      child: Text(l10n.remoteServerFilesMoveTo),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: DshColors.of(context).danger),
                      onPressed: _selected.isEmpty ? null : () => unawaited(_batchDelete()),
                      child: Text(l10n.commonDelete),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_searchOpen)
          if (state.searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Row(
                children: [
                  const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l10n.remoteServerFilesSearching)),
                  TextButton(onPressed: _sftp.cancelSearch, child: Text(l10n.remoteServerFilesSearchStop)),
                ],
              ),
            )
          else if (state.searchResults.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Text(
                _search.text.trim().isEmpty ? l10n.remoteServerFilesSearchHint : l10n.remoteServerFilesSearchEmpty,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
              child: Text(
                l10n.remoteServerFilesSearchResults(state.searchResults.length),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: ListPageCard(
                children: [
                  for (final entry in state.searchResults)
                    ListPageRow(
                      icon: entry.isDirectory
                          ? AppIcons.folder
                          : entry.isSymbolicLink
                          ? AppIcons.forward
                          : AppIcons.files,
                      title: entry.name,
                      subtitle: entry.path,
                      chevron: entry.isDirectory,
                      onTap: () {
                        _closeSearch();
                        if (entry.isDirectory) {
                          unawaited(_sftp.open(entry.path));
                        } else {
                          unawaited(
                            Navigator.of(context).push(ServerFilePreviewPage.route(host: widget.host, entry: entry)),
                          );
                        }
                      },
                      trailing: IconButton(
                        tooltip: l10n.commonMore,
                        icon: const Icon(AppIcons.more),
                        onPressed: () => unawaited(_menu(entry)),
                      ),
                    ),
                ],
              ),
            ),
          ]
        else if (state.failure case final failure?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Card(
              color: DshColors.of(context).dangerContainer,
              child: ListTile(
                leading: Icon(AppIcons.error, color: DshColors.of(context).onDangerContainer),
                title: Text(l10n.remoteServerFilesLoadFailed),
                subtitle: Text(sftpFailureText(l10n, failure), maxLines: 3, overflow: TextOverflow.ellipsis),
                trailing: TextButton(onPressed: _sftp.retry, child: Text(l10n.commonRetry)),
              ),
            ),
          )
        else if (state.phase != SftpPhase.ready)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            child: Text(l10n.remoteServerFilesEmpty, style: Theme.of(context).textTheme.bodyMedium),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: ListPageCard(
              children: [
                for (final entry in visible)
                  ListPageRow(
                    icon: _selecting
                        ? _selected.contains(entry.path)
                              ? AppIcons.checkboxOn
                              : AppIcons.checkboxOff
                        : entry.isDirectory
                        ? AppIcons.folder
                        : entry.isSymbolicLink
                        ? AppIcons.forward
                        : AppIcons.files,
                    title: entry.name,
                    subtitle: _subtitle(l10n, entry),
                    chevron: !_selecting && entry.isDirectory,
                    onTap: _selecting
                        ? () => setState(() {
                            if (!_selected.remove(entry.path)) _selected.add(entry.path);
                          })
                        : entry.isDirectory
                        ? () => _openFolder(entry)
                        : () =>
                              Navigator.of(context).push(ServerFilePreviewPage.route(host: widget.host, entry: entry)),
                    trailing: _selecting
                        ? null
                        : IconButton(
                            tooltip: l10n.commonMore,
                            icon: const Icon(AppIcons.more),
                            onPressed: () => unawaited(_menu(entry)),
                          ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  List<({String label, String path})> _crumbs(L10n l10n, String path) {
    final crumbs = <({String label, String path})>[(label: l10n.remoteServerFilesRoot, path: '/')];
    var built = '';
    for (final part in path.split('/').where((p) => p.isNotEmpty)) {
      built = '$built/$part';
      crumbs.add((label: part, path: built));
    }
    return crumbs;
  }
}

String _subtitle(L10n l10n, SftpEntry entry) {
  final parts = <String>[];
  if (entry.isDirectory) {
    parts.add(l10n.remoteServerFilesFolder);
  } else if (entry.size case final size?) {
    parts.add(_size(size));
  }
  if (entry.isSymbolicLink) parts.add(l10n.remoteServerFilesSymlink);
  if (entry.permissionBits case final mode?) parts.add(mode.toRadixString(8).padLeft(3, '0'));
  return parts.join(' · ');
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

/// The transfer centre: one row per upload/download, with progress, cancel and
/// a way to clear finished rows.
class _TransferSheet extends ConsumerStatefulWidget {
  const _TransferSheet({required this.host});

  final HostRef host;

  @override
  ConsumerState<_TransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends ConsumerState<_TransferSheet> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(sftpProvider(widget.host));
    final controller = ref.read(sftpProvider(widget.host).notifier);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(l10n.remoteServerFilesTransferTitle),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (state.transfers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                    child: Text(l10n.remoteServerFilesNoTransfers),
                  )
                else
                  SheetGroup(
                    children: [
                      for (final transfer in state.transfers)
                        _TransferRow(
                          transfer: transfer,
                          onCancel: transfer.running ? () => controller.cancel(transfer.id) : null,
                          onRetry: transfer.running
                              ? null
                              : () => unawaited(controller.retryTransfer(transfer.id)),
                        ),
                    ],
                  ),
                if (state.transfers.any((t) => !t.running))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: controller.clearFinished,
                        child: Text(l10n.remoteServerFilesClearFinished),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({required this.transfer, this.onCancel, this.onRetry});

  final SftpTransfer transfer;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final done = transfer.status == SftpTransferStatus.done;
    final failed = transfer.status == SftpTransferStatus.failed || transfer.status == SftpTransferStatus.cancelled;
    final tone = done
        ? colors.success
        : failed
        ? colors.danger
        : colors.textTertiary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(transfer.upload ? AppIcons.uploadToHost : AppIcons.download, size: 18, color: tone),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  transfer.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (transfer.running)
                TextButton(onPressed: onCancel, child: Text(l10n.commonCancel))
              else ...[
                Text(
                  _statusLabel(l10n, transfer, done, failed),
                  style: theme.textTheme.bodySmall?.copyWith(color: tone),
                ),
                // A settled transfer waits for an explicit retry; nothing is
                // replayed on its own.
                if (onRetry != null && !done)
                  TextButton(onPressed: onRetry, child: Text(l10n.remoteServerFilesRetryTransfer)),
              ],
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: transfer.fraction,
              minHeight: 4,
              color: failed ? colors.danger : null,
            ),
          ),
          if (transfer.total case final total?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${_size(transfer.done)} / ${_size(total)}',
                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
              ),
            ),
        ],
      ),
    );
  }

  String _statusLabel(L10n l10n, SftpTransfer transfer, bool done, bool failed) {
    if (done) return l10n.remoteServerFilesTransferDone;
    if (transfer.status == SftpTransferStatus.cancelled) return l10n.remoteServerFilesCancelled;
    return l10n.remoteServerFilesTransferFailed;
  }
}
