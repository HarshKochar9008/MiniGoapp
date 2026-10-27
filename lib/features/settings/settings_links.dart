import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import 'settings_components.dart';

/// Opens [uri] outside the app — browser, store, or mail. Says so when
/// nothing on the device can handle it instead of failing silently.
Future<bool> openExternalLink(BuildContext context, Uri uri) async {
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      return true;
    }
  } catch (_) {
    // Reported below, same as an unhandled link.
  }
  if (context.mounted) {
    showMiniSnack(
        context, 'Couldn’t open ${uri.host.isEmpty ? 'this link' : uri.host}.');
  }
  return false;
}

/// Drafts an email to MiniGo support with the app version and OS filled in,
/// so a report arrives with what's needed to reproduce it. Without a mail app
/// the address is copied instead.
Future<void> emailSupport(
  BuildContext context, {
  required String subject,
  String prompt = '',
}) async {
  PackageInfo? info;
  try {
    info = await PackageInfo.fromPlatform();
  } catch (_) {}

  final platform = Platform.isIOS
      ? 'iOS'
      : Platform.isAndroid
          ? 'Android'
          : Platform.operatingSystem;
  final details = [
    if (info != null) 'MiniGo ${info.version} (${info.buildNumber})',
    '$platform ${Platform.operatingSystemVersion}',
  ].join(' · ');

  // Encoded by hand: Uri.queryParameters writes spaces as '+', which several
  // mail apps then show literally.
  final query = {
    'subject': subject,
    'body': '$prompt\n\n—\n$details',
  }
      .entries
      .map((e) =>
          '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
      .join('&');
  final uri = Uri(
    scheme: 'mailto',
    path: AppConstants.supportEmail,
    query: query,
  );

  var opened = false;
  try {
    opened = await launchUrl(uri);
  } catch (_) {}
  if (opened || !context.mounted) return;

  await Clipboard.setData(
    const ClipboardData(text: AppConstants.supportEmail),
  );
  if (context.mounted) {
    showMiniSnack(
      context,
      'No email app found. Address copied: ${AppConstants.supportEmail}',
    );
  }
}
