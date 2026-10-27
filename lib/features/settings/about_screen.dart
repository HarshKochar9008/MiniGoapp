import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../Minigo/theme/mini_icons.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../../core/constants.dart';
import 'app_facts.dart';
import 'legal_screens.dart';
import 'release_notes.dart';
import 'settings_components.dart';
import 'settings_links.dart';
import 'update_check.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();
  bool _checkingForUpdates = false;

  void _push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  Future<void> _copy(String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.selectionClick();
    if (mounted) showMiniSnack(context, '$label copied');
  }

  void _showWhatsNew(PackageInfo? info) {
    final notes = ReleaseNotes.forVersion(info?.version);
    final String message;
    if (notes == null) {
      message = 'Release notes for this version aren’t available yet.';
    } else if (info != null && notes.version != info.version) {
      message = 'Notes for ${info.version} aren’t available yet. Here’s what '
          'arrived in ${notes.version}.';
    } else {
      message = notes.summary;
    }
    showMiniInfoSheet(
      context,
      icon: MiniIcons.whatsNew,
      title: notes == null ? 'What’s New' : 'What’s new in ${notes.version}',
      message: message,
      children: [
        for (final highlight in notes?.highlights ?? const <ReleaseHighlight>[])
          MiniSheetFact(
            icon: highlight.icon,
            title: highlight.title,
            body: highlight.body,
          ),
      ],
    );
  }

  Future<void> _checkForUpdates(PackageInfo info) async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        await _checkAppStore(info);
      case TargetPlatform.android when AppConstants.playStoreListed:
        await _openPlayListing(info);
      default:
        showMiniInfoSheet(
          context,
          icon: MiniIcons.update,
          title: 'Version ${info.version}',
          message: 'This build of MiniGo isn’t distributed through an app '
              'store, so it can’t check for updates on its own. Get new '
              'versions from wherever you installed this one.',
        );
    }
  }

  Future<void> _checkAppStore(PackageInfo info) async {
    setState(() => _checkingForUpdates = true);
    try {
      final result = await AppStoreUpdateCheck.run(info);
      if (!mounted) return;
      switch (result.status) {
        case UpdateStatus.upToDate:
          showMiniInfoSheet(
            context,
            icon: MiniIcons.success,
            tint: MiniColors.success,
            title: 'You’re up to date',
            message: 'MiniGo ${info.version} is the latest version on the '
                'App Store.',
          );
        case UpdateStatus.available:
          final storeUrl = result.storeUrl;
          showMiniInfoSheet(
            context,
            icon: MiniIcons.update,
            title: 'Update available',
            message: 'MiniGo ${result.storeVersion} is on the App Store. '
                'You have ${info.version}.',
            actionLabel: storeUrl == null ? null : 'Update on the App Store',
            onAction: storeUrl == null
                ? null
                : () => openExternalLink(context, storeUrl),
          );
        case UpdateStatus.notListed:
          showMiniInfoSheet(
            context,
            icon: MiniIcons.update,
            title: 'Can’t check for updates',
            message: 'MiniGo isn’t listed on the App Store in your region, so '
                'this build can’t check for updates. You’re on version '
                '${info.version} (build ${info.buildNumber}).',
          );
      }
    } catch (_) {
      if (mounted) {
        showMiniSnack(
          context,
          'Couldn’t reach the App Store. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _checkingForUpdates = false);
    }
  }

  Future<void> _openPlayListing(PackageInfo info) async {
    final market = Uri(
      scheme: 'market',
      host: 'details',
      queryParameters: {'id': info.packageName},
    );
    try {
      if (await launchUrl(market, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {
      // No Play Store app — fall back to the web listing.
    }
    if (!mounted) return;
    await openExternalLink(
      context,
      Uri.https('play.google.com', '/store/apps/details', {
        'id': info.packageName,
      }),
    );
  }

  void _showLicenses(PackageInfo? info) {
    showLicensePage(
      context: context,
      applicationName: 'MiniGo',
      applicationVersion:
          info == null ? null : '${info.version} (${info.buildNumber})',
      applicationIcon: const Padding(
        padding: EdgeInsets.all(12),
        child: _AppIconTile(size: 56),
      ),
      applicationLegalese: '© 2024 MiniGo',
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _packageInfo,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState != ConnectionState.done;
        final info = snapshot.data;
        return MiniSettingsPage(
          title: 'About MiniGo',
          children: [
            _IdentityCard(info: info, loading: loading),
            const _AboutAppSection(),
            _appInformation(info, loading),
            _support(),
            _legal(info),
            _Footer(info: info),
          ],
        );
      },
    );
  }

  Widget _appInformation(PackageInfo? info, bool loading) {
    Widget? pending(double width) =>
        loading ? MiniValueSkeleton(width: width) : null;
    String? orUnavailable(String? value) =>
        loading ? null : (value ?? 'Unavailable');

    final updateSubtitle = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'See if there’s a newer version on the App Store',
      TargetPlatform.android when AppConstants.playStoreListed =>
        'Opens MiniGo on Google Play',
      _ => 'Not available for this build',
    };
    final updateAccessory = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => MiniRowAccessory.none,
      TargetPlatform.android when AppConstants.playStoreListed =>
        MiniRowAccessory.external,
      _ => MiniRowAccessory.chevron,
    };

    return MiniSettingsSection(
      title: 'App information',
      children: [
        MiniSettingsRow(
          icon: MiniIcons.version,
          title: 'App version',
          value: orUnavailable(info?.version),
          trailing: pending(48),
          onLongPress:
              info == null ? null : () => _copy('Version', info.version),
        ),
        MiniSettingsRow(
          icon: MiniIcons.buildNumber,
          title: 'Build number',
          value: orUnavailable(info?.buildNumber),
          trailing: pending(28),
          onLongPress: info == null
              ? null
              : () => _copy('Build number', info.buildNumber),
        ),
        MiniSettingsRow(
          icon: MiniIcons.whatsNew,
          title: 'What’s New',
          subtitle: 'Highlights in this version',
          onTap: loading ? null : () => _showWhatsNew(info),
        ),
        MiniSettingsRow(
          icon: MiniIcons.update,
          title: 'Check for updates',
          subtitle: updateSubtitle,
          accessory: updateAccessory,
          busy: _checkingForUpdates,
          enabled: info != null,
          onTap: info == null ? null : () => _checkForUpdates(info),
        ),
      ],
    );
  }

  Widget _support() {
    final website = AppConstants.websiteUrl;
    return MiniSettingsSection(
      title: 'Support',
      children: [
        if (website != null)
          MiniSettingsRow(
            icon: MiniIcons.website,
            title: 'Official website',
            subtitle: Uri.parse(website).host,
            accessory: MiniRowAccessory.external,
            onTap: () => openExternalLink(context, Uri.parse(website)),
          ),
        MiniSettingsRow(
          icon: MiniIcons.mail,
          title: 'Contact support',
          subtitle: AppConstants.supportEmail,
          accessory: MiniRowAccessory.external,
          onTap: () => emailSupport(
            context,
            subject: 'MiniGo support',
            prompt: 'How can we help?',
          ),
        ),
      ],
    );
  }

  Widget _legal(PackageInfo? info) {
    final terms = AppConstants.termsOfServiceUrl;
    return MiniSettingsSection(
      title: 'Legal',
      children: [
        MiniSettingsRow(
          icon: MiniIcons.legal,
          title: 'Terms of Service',
          accessory: terms == null
              ? MiniRowAccessory.chevron
              : MiniRowAccessory.external,
          onTap: () => terms == null
              ? _push(const TermsScreen())
              : openExternalLink(context, Uri.parse(terms)),
        ),
        MiniSettingsRow(
          icon: MiniIcons.shield,
          title: 'Privacy Policy',
          onTap: () => _push(const PrivacyPolicyScreen()),
        ),
        MiniSettingsRow(
          icon: MiniIcons.licenses,
          title: 'Open-source licenses',
          subtitle: 'Software MiniGo is built with',
          onTap: () => _showLicenses(info),
        ),
      ],
    );
  }
}

class _IdentityCard extends StatelessWidget {
  final PackageInfo? info;
  final bool loading;

  const _IdentityCard({required this.info, required this.loading});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final info = this.info;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      decoration: miniCard(context, strong: true),
      child: Column(
        children: [
          const _AppIconTile(size: 76),
          const SizedBox(height: 16),
          Text(
            'MiniGo',
            style: GoogleFonts.outfit(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.7,
              height: 1.1,
              color: c.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Share simply. Stay in control.',
            textAlign: TextAlign.center,
            style: MiniText.bodySoft.copyWith(color: c.inkSoft),
          ),
          const SizedBox(height: 16),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: loading
                ? MiniSkeleton(
                    key: const ValueKey('loading'),
                    width: 128,
                    height: 28,
                    borderRadius: BorderRadius.circular(MiniRadius.pill),
                  )
                : Container(
                    key: const ValueKey('version'),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                    decoration: BoxDecoration(
                      color: c.sand,
                      borderRadius: BorderRadius.circular(MiniRadius.pill),
                    ),
                    child: Text(
                      info == null
                          ? 'Version unavailable'
                          : 'Version ${info.version} (${info.buildNumber})',
                      style: MiniText.small.copyWith(
                        color: c.inkSoft,
                        fontWeight: FontWeight.w500,
                        height: 1.1,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _AboutAppSection extends StatelessWidget {
  const _AboutAppSection();

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return MiniSettingsSection(
      title: 'About the app',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'MiniGo makes sharing files simple and convenient. Transfer '
                'files using a short sharing code, without unnecessary '
                'complexity.',
                style: GoogleFonts.outfit(
                  fontSize: 15,
                  height: 1.5,
                  color: c.ink,
                ),
              ),
              const SizedBox(height: 16),
              MiniFactLine(
                icon: MiniIcons.sharingCode,
                text: 'Send with a ${AppConstants.codeLength}-character code '
                    'or QR code',
              ),
              const SizedBox(height: 10),
              MiniFactLine(
                icon: MiniIcons.file,
                text: 'Up to ${AppFacts.maxFiles} files per transfer, '
                    '${AppFacts.maxFileSize} each',
              ),
              const SizedBox(height: 10),
              MiniFactLine(
                icon: MiniIcons.timer,
                text: 'Transfers expire after ${AppFacts.transferLifetime}',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  final PackageInfo? info;
  const _Footer({required this.info});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final info = this.info;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 34, 24, 0),
      child: Column(
        children: [
          Text(
            'Made with care by the MiniGo team.',
            textAlign: TextAlign.center,
            style: MiniText.small.copyWith(color: c.inkSoft),
          ),
          if (info != null) ...[
            const SizedBox(height: 4),
            Text(
              'Version ${info.version} · Build ${info.buildNumber}',
              textAlign: TextAlign.center,
              style: MiniText.small.copyWith(color: c.inkFaint, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

/// The launcher icon as a rounded tile, the way the home screen shows it.
class _AppIconTile extends StatelessWidget {
  final double size;
  const _AppIconTile({required this.size});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final radius = BorderRadius.circular(size * 0.235);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: miniCardShadow(context, strong: true),
      ),
      // Painted over the artwork so the white tile keeps an edge on a white
      // card.
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: c.divider),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Image.asset(
          'assets/icon/app_icon.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
          semanticLabel: 'MiniGo app icon',
          errorBuilder: (_, __, ___) => const ColoredBox(
            color: Colors.white,
            child: Center(
              child: Icon(MiniIcons.send, color: MiniColors.blue600),
            ),
          ),
        ),
      ),
    );
  }
}
