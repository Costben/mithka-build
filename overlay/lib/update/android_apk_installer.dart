//
//  android_apk_installer.dart
//
//  In-app replacement for the browser hand-off used by the stock Android
//  update prompt: download the release APK into the app cache, verify it
//  against the SHA-256 GitHub publishes for the asset, and hand the verified
//  file to the system package installer through the same open_filex path the
//  rest of the app already uses for downloaded APKs.
//
//  Nothing here touches the installed package: Android's package installer
//  owns the swap, so a failed or cancelled download leaves the running build
//  untouched.
//

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../chat/file_opener.dart';
import '../components/app_dialog.dart';
import '../components/ui_components.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import 'release_feed.dart';

enum AndroidUpdateResultKind { installed, cancelled, failed }

enum AndroidUpdateStage { downloading, verifying }

/// Progress reported to the modal sheet.
class AndroidUpdateProgress {
  const AndroidUpdateProgress(
    this.stage, {
    this.receivedBytes = 0,
    this.totalBytes = 0,
  });

  final AndroidUpdateStage stage;
  final int receivedBytes;
  final int totalBytes;

  /// Null while the server has not told us how big the asset is.
  double? get fraction =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _CancelToken {
  bool cancelled = false;

  void cancel() => cancelled = true;

  void throwIfCancelled() {
    if (cancelled) throw const _Cancelled();
  }
}

/// Downloads [asset], verifies it, then opens the system installer.
///
/// Returns [AndroidUpdateResultKind.installed] once the installer has been
/// handed the file — the user still confirms the swap in the system dialog.
Future<AndroidUpdateResultKind> runAndroidApkUpdate(
  BuildContext context, {
  required ReleaseAsset asset,
  required String version,
}) async {
  final outcome = await showGeneralDialog<AndroidUpdateResultKind>(
    context: context,
    barrierDismissible: false,
    barrierLabel: AppStrings.t(AppStringKeys.updateDownloadingTitle),
    barrierColor: Colors.black.withValues(alpha: 0.52),
    transitionDuration: AppMotion.duration(context, AppMotion.responsive),
    transitionBuilder: AppMotion.dialogTransition,
    pageBuilder: (_, _, _) =>
        _AndroidUpdateSheet(asset: asset, version: version),
  );
  final result = outcome ?? AndroidUpdateResultKind.cancelled;
  if (result != AndroidUpdateResultKind.installed) return result;

  final file = _stagedFile;
  _stagedFile = null;
  if (file == null || !file.existsSync()) return AndroidUpdateResultKind.failed;
  if (!context.mounted) return AndroidUpdateResultKind.installed;
  await openDownloadedFile(context, file.path, mimeType: apkMime);
  return AndroidUpdateResultKind.installed;
}

/// The sheet hands the verified file back through this slot so the caller can
/// open the installer after the sheet has already popped.
File? _stagedFile;

class _AndroidUpdateSheet extends StatefulWidget {
  const _AndroidUpdateSheet({required this.asset, required this.version});

  final ReleaseAsset asset;
  final String version;

  @override
  State<_AndroidUpdateSheet> createState() => _AndroidUpdateSheetState();
}

class _AndroidUpdateSheetState extends State<_AndroidUpdateSheet> {
  final _cancellation = _CancelToken();
  AndroidUpdateProgress _progress = const AndroidUpdateProgress(
    AndroidUpdateStage.downloading,
  );
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _settle(AndroidUpdateResultKind result) {
    if (_settled || !mounted) return;
    _settled = true;
    Navigator.of(context).pop(result);
  }

  Future<void> _run() async {
    File? target;
    try {
      target = await _targetFile(widget.version);
      await _download(widget.asset, target, (progress) {
        if (mounted) setState(() => _progress = progress);
      }, _cancellation);
      if (_settled) return;
      _stagedFile = target;
      _settle(AndroidUpdateResultKind.installed);
    } on _Cancelled {
      _settle(AndroidUpdateResultKind.cancelled);
    } catch (_) {
      _settle(AndroidUpdateResultKind.failed);
    } finally {
      if (_settled && _stagedFile == null && target != null) {
        // Either the run was cancelled or it failed; never leave a partial
        // package behind for the next attempt to pick up.
        try {
          if (target.existsSync()) target.deleteSync();
        } catch (_) {}
      }
    }
  }

  void _cancel() {
    _cancellation.cancel();
    _settle(AndroidUpdateResultKind.cancelled);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fraction = _progress.fraction;
    final received = _progress.receivedBytes;
    final total = _progress.totalBytes;
    return AppDialogSurface(
      title: AppStrings.t(AppStringKeys.updateDownloadingTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            AppStrings.t(
              _progress.stage == AndroidUpdateStage.downloading
                  ? AppStringKeys.updateStageDownloading
                  : AppStringKeys.updateStageVerifying,
            ),
            textAlign: TextAlign.center,
            style: AppTextStyle.body(c.dialogText),
          ),
          const SizedBox(height: 16),
          AppProgressBar(value: fraction ?? _stageFallbackFraction, height: 4),
          const SizedBox(height: 10),
          Text(
            total > 0
                ? AppStrings.t(AppStringKeys.updateProgressOfTotal, {
                    'value1': _formatBytes(received),
                    'value2': _formatBytes(total),
                  })
                : widget.version,
            textAlign: TextAlign.center,
            style: AppTextStyle.footnote(c.textSecondary),
          ),
        ],
      ),
      actions: [
        AppDialogAction(
          label: AppStrings.t(AppStringKeys.confirmCancel),
          onTap: _cancel,
        ),
      ],
    );
  }

  double get _stageFallbackFraction =>
      _progress.stage == AndroidUpdateStage.downloading ? 0 : 0.95;
}

/// Where the package is staged. The app cache is the only location the
/// open_filex FileProvider exposes without extra paths.
Future<File> _targetFile(String version) async {
  final directory = Directory(
    '${(await getTemporaryDirectory()).path}/mithka-updates',
  );
  if (!directory.existsSync()) {
    await directory.create(recursive: true);
  }
  final safe = version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
  return File('${directory.path}/mithka-$safe.apk');
}

Future<void> _download(
  ReleaseAsset asset,
  File target,
  void Function(AndroidUpdateProgress) onProgress,
  _CancelToken cancellation,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final digestSink = _DigestSink();
  RandomAccessFile? handle;
  try {
    final request = await client.getUrl(Uri.parse(asset.url));
    request.headers.set(HttpHeaders.userAgentHeader, releaseFeedUserAgent);
    request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode} for ${asset.url}');
    }
    final total = asset.size > 0 ? asset.size : response.contentLength;
    handle = await target.open(mode: FileMode.write);
    final hasher = sha256.startChunkedConversion(digestSink);
    var received = 0;
    await for (final chunk in response) {
      cancellation.throwIfCancelled();
      await handle.writeFrom(chunk);
      hasher.add(chunk);
      received += chunk.length;
      onProgress(
        AndroidUpdateProgress(
          AndroidUpdateStage.downloading,
          receivedBytes: received,
          totalBytes: total,
        ),
      );
    }
    hasher.close();
    await handle.close();
    handle = null;

    onProgress(
      AndroidUpdateProgress(
        AndroidUpdateStage.verifying,
        receivedBytes: received,
        totalBytes: total,
      ),
    );
    cancellation.throwIfCancelled();

    if (asset.size > 0 && received != asset.size) {
      throw const HttpException('downloaded size does not match the release');
    }
    final expected = asset.sha256;
    if (expected != null && digestSink.value?.toString() != expected) {
      throw const HttpException('downloaded package failed SHA-256 check');
    }
  } finally {
    await handle?.close();
    client.close(force: true);
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}
