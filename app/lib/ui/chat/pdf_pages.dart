// Natively rendered PDF pages: the phone's PDF renderer turns each page into a
// PNG through [FilesChannel], so a document reads like the chat's own preview
// instead of a WebView. Extracted from the artifact preview so the SSH file
// preview can show a remote PDF the same way.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/artifacts.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

class PdfPagesView extends ConsumerStatefulWidget {
  const PdfPagesView({super.key, required this.path});

  /// Local file path of the PDF.
  final String path;

  @override
  ConsumerState<PdfPagesView> createState() => _PdfPagesViewState();
}

class _PdfPagesViewState extends ConsumerState<PdfPagesView> {
  late final FilesChannel _channel = ref.read(filesChannelProvider);
  late final Future<List<({int width, int height})>> _pages = _channel.pdfInfo(widget.path);

  @override
  void dispose() {
    unawaited(_channel.pdfClose().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    return FutureBuilder(
      future: _pages,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                l10n.viewArtifactPdfFailed,
                textAlign: TextAlign.center,
                style: TextStyle(color: dsh.textTertiary),
              ),
            ),
          );
        }
        final pages = snapshot.data;
        if (pages == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth - 24;
            final pixels = (width * MediaQuery.devicePixelRatioOf(context)).round();
            return InteractiveViewer(
              maxScale: 4,
              child: ListView.separated(
                padding: EdgeInsets.fromLTRB(12, 4, 12, MediaQuery.paddingOf(context).bottom + 24),
                itemCount: pages.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  if (i == pages.length) {
                    return Center(
                      child: Text(
                        l10n.viewArtifactPages(pages.length),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                      ),
                    );
                  }
                  final page = pages[i];
                  return AspectRatio(
                    aspectRatio: page.width / (page.height == 0 ? 1 : page.height),
                    child: _PdfPage(channel: _channel, path: widget.path, index: i, pixels: pixels),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _PdfPage extends StatefulWidget {
  const _PdfPage({required this.channel, required this.path, required this.index, required this.pixels});

  final FilesChannel channel;
  final String path;
  final int index;
  final int pixels;

  @override
  State<_PdfPage> createState() => _PdfPageState();
}

class _PdfPageState extends State<_PdfPage> {
  late final Future<Uint8List> _png = widget.channel.pdfPage(widget.path, widget.index, widget.pixels);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 6, offset: const Offset(0, 1))],
      ),
      child: FutureBuilder<Uint8List>(
        future: _png,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            return snapshot.hasError ? const Center(child: Icon(AppIcons.imageBroken)) : const SizedBox.expand();
          }
          return Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            semanticLabel: l10n.viewArtifactPage(widget.index + 1),
          );
        },
      ),
    );
  }
}
