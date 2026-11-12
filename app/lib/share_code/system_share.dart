import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

/// Service-level exports have no originating widget. Anchor their iPad popover
/// in the current Flutter window, including when it occupies a split view.
Future<ShareResult> systemShare(ShareParams params) {
  if (!Platform.isIOS || params.sharePositionOrigin != null) {
    return SharePlus.instance.share(params);
  }
  final view = WidgetsBinding.instance.platformDispatcher.views.single;
  final size = view.physicalSize / view.devicePixelRatio;
  return SharePlus.instance.share(ShareParams(
    text: params.text,
    subject: params.subject,
    title: params.title,
    uri: params.uri,
    files: params.files,
    fileNameOverrides: params.fileNameOverrides,
    previewThumbnail: params.previewThumbnail,
    excludedCupertinoActivities: params.excludedCupertinoActivities,
    downloadFallbackEnabled: params.downloadFallbackEnabled,
    mailToFallbackEnabled: params.mailToFallbackEnabled,
    sharePositionOrigin: Rect.fromCenter(center: size.center(Offset.zero), width: 1, height: 1),
  ));
}
