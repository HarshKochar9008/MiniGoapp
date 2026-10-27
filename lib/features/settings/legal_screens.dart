import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../Minigo/theme/mini_icons.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../core/constants.dart';
import 'app_facts.dart';
import 'settings_components.dart';
import 'settings_links.dart';

/// Plain-language privacy policy built from what this version of the app and
/// its backend actually do. When [AppConstants.privacyPolicyUrl] is set it
/// also links out to the published policy.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  /// The flag reads .env, which throws if it never loaded (a build configured
  /// only through --dart-define). R2 can't be switched on then, so it's off.
  static bool get _usesR2Storage {
    try {
      return AppConstants.useR2Storage;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fullPolicy = AppConstants.privacyPolicyUrl;
    return MiniSettingsPage(
      title: 'Privacy Policy',
      eyebrow: 'MiniGo',
      children: [
        const _Intro(
          'How this version of MiniGo handles your information, in plain '
          'language: what’s collected and why, who processes it, and how long '
          'it’s kept.',
        ),
        _DocumentSection(
          title: 'What MiniGo collects',
          blocks: [
            _Bullets([
              'An anonymous account ID and your ${AppConstants.codeLength}-'
                  'character sharing code, created the first time you open '
                  'the app.',
              'Your public encryption key, so other people can encrypt files '
                  'for you.',
              'A nickname, if you choose to add one.',
              'A notification token, if you allow notifications, so you can '
                  'be told when files arrive.',
              'The files you send, with their names, sizes, and delivery '
                  'status.',
              'Crash reports if the app crashes: device and app details, your '
                  'account ID and sharing code, and a log of recent activity '
                  '(for example, how many files were sent and their total '
                  'size).',
            ]),
          ],
        ),
        const _DocumentSection(
          title: 'What MiniGo doesn’t collect',
          blocks: [
            _Bullets([
              'Your name, email address, or phone number.',
              'Your contacts or location.',
              'Files you haven’t chosen to send.',
              'Advertising identifiers — MiniGo has no ads.',
            ]),
          ],
        ),
        const _DocumentSection(
          title: 'How it’s used',
          blocks: [
            _Paragraph(
              'To deliver your transfers, send the notifications you’ve '
              'allowed, keep the service secure, and fix crashes.',
            ),
          ],
        ),
        const _DocumentSection(
          title: 'Encrypted files',
          blocks: [
            _Paragraph(
              'When a transfer is end-to-end encrypted, MiniGo’s servers only '
              'store data they can’t read — the key to open it exists only on '
              'the recipient’s device. File names, sizes, and transfer times '
              'aren’t encrypted, because they’re needed to deliver the '
              'transfer.',
            ),
            _Paragraph(
              'If a recipient’s app can’t receive encrypted files, the sender '
              'is asked before anything is sent without encryption.',
            ),
          ],
        ),
        _DocumentSection(
          title: 'Service providers',
          blocks: [
            const _Paragraph('MiniGo relies on these services to run:'),
            _Bullets([
              'Supabase — accounts, transfer records, and file storage.',
              if (_usesR2Storage) 'Cloudflare R2 — file storage.',
              'Google Firebase — notifications and crash reports.',
              'Google Fonts — the app’s typefaces, downloaded the first time '
                  'it runs.',
            ]),
          ],
        ),
        _DocumentSection(
          title: 'How long it’s kept',
          blocks: [
            _Bullets([
              'Files: ${AppFacts.transferLifetime} after they’re sent, or '
                  'until the room they were sent in closes.',
              'Transfer records: ${AppFacts.recordRetention} after sending.',
              'Nickname and notification token: until you change them or '
                  'delete your account.',
              'Sharing code: deactivated when you delete your account, and '
                  'kept on record so it’s never given to anyone else.',
              'Crash reports: kept by Firebase Crashlytics under Google’s '
                  'retention policy.',
            ]),
          ],
        ),
        const _DocumentSection(
          title: 'Your choices',
          blocks: [
            _Bullets([
              'Turn notifications off at any time in your phone’s Settings.',
              'Clear what MiniGo keeps on this device from Privacy & '
                  'Security.',
              'Delete your account from Privacy & Security → Sign out and '
                  'delete account.',
            ]),
          ],
        ),
        MiniSettingsSection(
          title: 'Questions',
          children: [
            MiniSettingsRow(
              icon: MiniIcons.mail,
              title: 'Email us about privacy',
              subtitle: AppConstants.supportEmail,
              accessory: MiniRowAccessory.external,
              onTap: () => emailSupport(context, subject: 'MiniGo privacy'),
            ),
            if (fullPolicy != null)
              MiniSettingsRow(
                icon: MiniIcons.document,
                title: 'Read the full privacy policy',
                accessory: MiniRowAccessory.external,
                onTap: () => openExternalLink(context, Uri.parse(fullPolicy)),
              ),
          ],
        ),
      ],
    );
  }
}

/// In-app terms, shown until [AppConstants.termsOfServiceUrl] points at a
/// published version.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return MiniSettingsPage(
      title: 'Terms of Service',
      eyebrow: 'MiniGo',
      children: [
        const _Intro('The short version of the rules for using MiniGo.'),
        const _DocumentSection(
          title: 'Provided as-is',
          blocks: [_Paragraph('MiniGo is provided as-is.')],
        ),
        const _DocumentSection(
          title: 'Your content',
          blocks: [
            _Paragraph('You are responsible for the content you share.'),
          ],
        ),
        _DocumentSection(
          title: 'Temporary storage',
          blocks: [
            _Paragraph(
              'MiniGo doesn’t store files permanently — transfers expire after '
              '${AppFacts.transferLifetime}.',
            ),
          ],
        ),
        _DocumentSection(
          title: 'Limits',
          blocks: [
            _Paragraph(
              'Each transfer can include up to ${AppFacts.maxFiles} files of up '
              'to ${AppFacts.maxFileSize} each.',
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 26, 26, 0),
          child: Text(
            '© 2024 MiniGo. All rights reserved.',
            style: MiniText.small.copyWith(color: c.inkSoft),
          ),
        ),
      ],
    );
  }
}

class _Intro extends StatelessWidget {
  final String text;
  const _Intro(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
        child: Text(
          text,
          style: MiniText.bodySoft.copyWith(
            color: context.mini.inkSoft,
            height: 1.5,
          ),
        ),
      );
}

class _DocumentSection extends StatelessWidget {
  final String title;
  final List<Widget> blocks;

  const _DocumentSection({required this.title, required this.blocks});

  @override
  Widget build(BuildContext context) {
    return MiniSettingsSection(
      title: title,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < blocks.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                blocks[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

TextStyle _documentText(BuildContext context) => GoogleFonts.outfit(
      fontSize: 14.5,
      height: 1.5,
      color: context.mini.ink,
    );

class _Paragraph extends StatelessWidget {
  final String text;
  const _Paragraph(this.text);

  @override
  Widget build(BuildContext context) =>
      Text(text, style: _documentText(context));
}

class _Bullets extends StatelessWidget {
  final List<String> items;
  const _Bullets(this.items);

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 5,
                  height: 5,
                  margin: const EdgeInsets.only(top: 9, right: 12),
                  decoration: BoxDecoration(
                    color: c.inkFaint,
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Text(items[i], style: _documentText(context)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
