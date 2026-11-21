// 服务器文件预览 / 编辑 over the shared SFTP state layer. Reads through
// `sftpProvider.readText`, writes only after an explicit overwrite
// confirmation, and never keeps its own SSH session.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/hosts_state.dart';
import '../../state/sftp_state.dart';
import '../chat/pdf_pages.dart';
import '../chat/render/code_block.dart';
import '../common/app_dialog.dart';
import '../common/brief_notice.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'sftp_failure_text.dart';
import 'sftp_temp_dir.dart';

class ServerFilePreviewPage extends ConsumerStatefulWidget {
  const ServerFilePreviewPage({super.key, required this.host, required this.entry});

  final HostRef host;
  final SftpEntry entry;

  static Route<void> route({required HostRef host, required SftpEntry entry}) => MaterialPageRoute<void>(
    builder: (_) => ServerFilePreviewPage(host: host, entry: entry),
  );

  @override
  ConsumerState<ServerFilePreviewPage> createState() => _ServerFilePreviewPageState();
}

/// What the page can show: text (and code), an image, or a PDF. Anything else
/// is still shown as text, which is what a remote file browser should do.
enum _PreviewKind { text, image, pdf }

const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

_PreviewKind _kindOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return _PreviewKind.text;
  final extension = name.substring(dot + 1).toLowerCase();
  if (_imageExtensions.contains(extension)) return _PreviewKind.image;
  if (extension == 'pdf') return _PreviewKind.pdf;
  return _PreviewKind.text;
}

class _ServerFilePreviewPageState extends ConsumerState<ServerFilePreviewPage> {
  final _text = TextEditingController();
  String _original = '';
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  String? _error;

  late final _kind = _kindOf(widget.entry.name);

  /// Bytes of an image preview.
  Uint8List? _image;

  /// Local copy of a PDF, downloaded before the native renderer sees it.
  String? _pdfPath;

  static const _maxImageBytes = 16 * 1024 * 1024;
  static const _maxPdfBytes = 64 * 1024 * 1024;

  SftpController get _sftp => ref.read(sftpProvider(widget.host).notifier);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_kind == _PreviewKind.image) return _loadImage();
    if (_kind == _PreviewKind.pdf) return _loadPdf();
    try {
      final text = await _sftp.readText(widget.entry.path);
      if (!mounted) return;
      _text.text = text;
      _original = text;
      setState(() => _loading = false);
    } on SftpFailure catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = sftpFailureText(context.l10n, error);
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await _sftp.readBytes(widget.entry.path, maxBytes: _maxImageBytes);
      if (!mounted) return;
      setState(() {
        _image = bytes;
        _loading = false;
      });
    } on SftpFailure catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = sftpFailureText(context.l10n, error);
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = context.l10n.remoteServerFilesOperationFailed;
        });
      }
    }
  }

  /// A PDF is rendered by the phone's own renderer, which needs a local file:
  /// download it to the cache first, then hand the path over.
  Future<void> _loadPdf() async {
    try {
      final size = widget.entry.size;
      if (size != null && size > _maxPdfBytes) {
        throw const SftpFailure(SftpFailureKind.tooLarge);
      }
      final local = await sftpTempPath(widget.host, widget.entry.name);
      await _sftp.download(remotePath: widget.entry.path, localPath: local);
      if (!mounted) return;
      // The path is this download's own, so its row is the one that wrote it.
      final transfer = ref
          .read(sftpProvider(widget.host))
          .transfers
          .where((t) => t.localPath == local && !t.upload)
          .firstOrNull;
      if (transfer == null || transfer.status != SftpTransferStatus.done) {
        throw const SftpFailure(SftpFailureKind.connectionLost);
      }
      setState(() {
        _pdfPath = local;
        _loading = false;
      });
    } on SftpFailure catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = sftpFailureText(context.l10n, error);
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = context.l10n.remoteServerFilesOperationFailed;
        });
      }
    }
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    if (_saving) return;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.remoteServerFilesOverwriteTitle),
        content: Text('${l10n.remoteServerFilesOverwriteBody}\n\n${widget.entry.path}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.remoteServerFilesSave),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await _sftp.writeText(widget.entry.path, _text.text);
      _original = _text.text;
      HapticFeedback.selectionClick();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _editing = false;
      });
      showBriefNotice(context, l10n.remoteServerFilesSaved);
    } on SftpFailure catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showBriefNotice(context, sftpFailureText(l10n, error));
    } on Object {
      if (!mounted) return;
      setState(() => _saving = false);
      showBriefNotice(context, l10n.remoteServerFilesSaveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dirty = _text.text != _original;
    final actions = <Widget>[
      if (!_loading && _error == null && _kind == _PreviewKind.text)
        IconButton(
          tooltip: _editing ? l10n.commonCancel : l10n.remoteServerFilesEdit,
          onPressed: _saving
              ? null
              : () => setState(() {
                  _editing = !_editing;
                  if (!_editing) _text.text = _original;
                }),
          icon: Icon(_editing ? AppIcons.back : AppIcons.edit),
        ),
      if (_editing)
        IconButton(
          tooltip: l10n.remoteServerFilesSave,
          onPressed: dirty && !_saving ? _save : null,
          icon: _saving
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(AppIcons.save),
        ),
    ];
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error case final error?) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error, textAlign: TextAlign.center),
        ),
      );
    } else if (_kind == _PreviewKind.image && _image != null) {
      body = InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Image.memory(_image!, fit: BoxFit.contain, semanticLabel: widget.entry.name),
          ),
        ),
      );
    } else if (_kind == _PreviewKind.pdf && _pdfPath != null) {
      body = PdfPagesView(path: _pdfPath!);
    } else if (_editing) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: TextField(
          controller: _text,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: AppType.mono(size: 13, height: 1.5),
          decoration: const InputDecoration(border: InputBorder.none),
          onChanged: (_) => setState(() {}),
        ),
      );
    } else {
      // Read-only view: the same highlighter the chat's code blocks use, with
      // the language taken from the file name. A type it does not know stays
      // plain text — no rich spans for a whole file just to colour nothing.
      final style = AppType.mono(size: 13, height: 1.5);
      final language = languageForPath(widget.entry.name);
      body = SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: language == null
            ? SelectableText(_text.text, style: style)
            : SelectableText.rich(
                highlightCode(_text.text, language, Theme.of(context).brightness, style: style),
              ),
      );
    }
    return AppPage(
      title: widget.entry.name,
      subtitle: Text(widget.entry.path, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: actions,
      slivers: [SliverFillRemaining(hasScrollBody: false, child: body)],
    );
  }
}
