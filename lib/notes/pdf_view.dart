import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

/// Shows a PDF file: continuous vertical scroll, pinch zoom, fit-width by
/// default and a "page / total" indicator.
///
/// Requires nothing in `main()` when only this widget is used (pdfrx
/// initializes itself when the first viewer is built). Call
/// `pdfrxFlutterInitialize()` at startup only if you use the pdfrx document
/// API directly before any viewer exists.
class NotesPdfView extends StatelessWidget {
  const NotesPdfView({super.key, required this.filePath, this.initialPage = 1});

  final String filePath;

  /// 1-based page shown when the document opens.
  final int initialPage;

  @override
  Widget build(BuildContext context) => _PdfBody(filePath: filePath, initialPage: initialPage);
}

class _PdfBody extends StatefulWidget {
  const _PdfBody({required this.filePath, required this.initialPage});
  final String filePath;
  final int initialPage;

  @override
  State<_PdfBody> createState() => _PdfBodyState();
}

class _PdfBodyState extends State<_PdfBody> {
  final _controller = PdfViewerController();
  final _page = ValueNotifier<({int page, int count})>((page: 0, count: 0));

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  void _update() {
    if (!_controller.isReady) return;
    _page.value = (page: _controller.pageNumber ?? 1, count: _controller.pageCount);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (!File(widget.filePath).existsSync()) {
      return Center(
        child: Text('PDF not found', style: TextStyle(color: cs.error)),
      );
    }
    return ColoredBox(
      color: cs.surfaceContainerHighest,
      child: Stack(
        children: [
          PdfViewer.file(
            widget.filePath,
            controller: _controller,
            initialPageNumber: widget.initialPage,
            params: PdfViewerParams(
              margin: 8,
              backgroundColor: cs.surfaceContainerHighest,
              // Fit-width on open, adapts on rotation / window resize.
              sizeDelegateProvider: const PdfViewerSizeDelegateProviderSmart(
                maxPagesVisible: 1.0,
                smartMaxScale: 1.6,
              ),
              onViewerReady: (doc, controller) => _update(),
              onPageChanged: (_) => _update(),
              errorBannerBuilder: (context, error, stackTrace, documentRef) =>
                  Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Could not open PDF',
                      style: TextStyle(color: cs.error)),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: IgnorePointer(
              child: Center(
                child: ValueListenableBuilder(
                  valueListenable: _page,
                  builder: (context, v, _) => v.count == 0
                      ? const SizedBox.shrink()
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            color: cs.inverseSurface.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 5),
                            child: Text(
                              '${v.page} / ${v.count}',
                              style: TextStyle(
                                  color: cs.onInverseSurface, fontSize: 13),
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the system share sheet for the PDF at [filePath].
Future<void> sharePdf(String filePath, {String? title}) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(filePath, mimeType: 'application/pdf')],
      title: title,
      subject: title,
    ),
  );
}
