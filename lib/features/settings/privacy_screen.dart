import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: ListView(
          children: [
            // Header with back button
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 20, 6),
              child: Row(
                children: [
                  Material(
                    color: c.sand,
                    shape: const CircleBorder(),
                    child: InkWell(
                      onTap: () => Navigator.pop(context),
                      customBorder: const CircleBorder(),
                      child: Padding(
                        padding: const EdgeInsets.all(9),
                        child: Icon(Icons.arrow_back_rounded,
                            color: c.ink, size: 20),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('MiniGo',
                            style: MiniText.label.copyWith(color: c.inkFaint)),
                        const SizedBox(height: 3),
                        Text('Privacy & Security',
                            style: MiniText.title.copyWith(color: c.ink)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Summary banner
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: MiniColors.success
                    .withValues(alpha: context.isDarkMini ? 0.16 : 0.10),
                borderRadius: BorderRadius.circular(MiniRadius.card),
              ),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: MiniColors.success.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.lock_rounded,
                        size: 21, color: MiniColors.success),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'MiniGo is designed to minimise data collection. '
                      'No accounts. No permanent storage. No tracking.',
                      style: GoogleFonts.outfit(
                        fontSize: 13.5,
                        height: 1.45,
                        fontWeight: FontWeight.w500,
                        color: MiniColors.success,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            SectionHeader(title: 'Data we collect'),
            _PolicyCard(
              children: [
                _PolicySection(
                  icon: Icons.fingerprint_rounded,
                  title: 'Anonymous device identity',
                  body:
                      'When you first open MiniGo, a random 6-character code and anonymous '
                      'user ID are generated on your device and stored on our servers. No name, '
                      'email, or phone number is ever collected.',
                  c: c,
                ),
                _PolicySection(
                  icon: Icons.upload_file_rounded,
                  title: 'Temporary file storage',
                  body:
                      'Files you send are uploaded to our secure cloud storage for delivery only. '
                      'They are automatically deleted after 24 hours. We do not read, scan, '
                      'or process the contents of your files.',
                  c: c,
                ),
                _PolicySection(
                  icon: Icons.notifications_rounded,
                  title: 'Push notification token',
                  body:
                      'If you enable push notifications, a Firebase Cloud Messaging (FCM) '
                      'token is stored alongside your user ID so that incoming-transfer alerts '
                      'can be delivered. This token contains no personal information.',
                  c: c,
                ),
              ],
            ),

            SectionHeader(title: 'What we do NOT collect'),
            _PolicyCard(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
              children: [
                _BulletList(
                  items: const [
                    'Your name, email address, or phone number',
                    'Location data or device identifiers',
                    'Browsing history or analytics events',
                    'File contents — only binary chunks for delivery',
                  ],
                  c: c,
                ),
              ],
            ),

            SectionHeader(title: 'Security'),
            _PolicyCard(
              children: [
                _PolicySection(
                  icon: Icons.https_rounded,
                  title: 'Encrypted in transit',
                  body:
                      'All communication between the app and our servers uses HTTPS/TLS. '
                      'Files are transferred over encrypted connections.',
                  c: c,
                ),
                _PolicySection(
                  icon: Icons.timer_rounded,
                  title: 'Short-lived transfers',
                  body:
                      'Transfers expire after 24 hours. After expiry, files are removed '
                      'from storage and the transfer record is marked expired.',
                  c: c,
                ),
                _PolicySection(
                  icon: Icons.code_rounded,
                  title: 'Code-based sharing',
                  body:
                      'Files can only be received by the person who knows your code. '
                      'There is no public listing of users or codes.',
                  c: c,
                ),
              ],
            ),

            SectionHeader(title: 'Your rights'),
            _PolicyCard(
              padding: const EdgeInsets.all(18),
              children: [
                Text(
                  'You can delete all local data at any time using "Clear all local data" in Settings. This removes your code, identity, and queued transfers '
                  'from this device and signs you out of the backend.',
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    height: 1.55,
                    color: c.inkSoft,
                  ),
                ),
              ],
            ),

            SectionHeader(title: 'Contact'),
            _PolicyCard(
              padding: const EdgeInsets.all(18),
              children: [
                Text(
                  'For privacy questions or data removal requests, '
                  'contact the developer through the app store listing.',
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    height: 1.55,
                    color: c.inkSoft,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

/// Raised panel wrapper. Multiple children are hairline-separated.
class _PolicyCard extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets padding;
  const _PolicyCard({
    required this.children,
    this.padding = const EdgeInsets.symmetric(vertical: 4),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: padding,
      decoration: miniCard(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1) const HairLine(indent: 60),
          ],
        ],
      ),
    );
  }
}

class _PolicySection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final MiniThemeExtension c;
  const _PolicySection({
    required this.icon,
    required this.title,
    required this.body,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MiniIconPlate(
            icon: icon,
            tint: c.accent,
            size: 40,
            iconSize: 19,
            radius: 9,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.outfit(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.2,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  body,
                  style: GoogleFonts.outfit(
                    fontSize: 13.5,
                    height: 1.5,
                    color: c.inkSoft,
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

class _BulletList extends StatelessWidget {
  final List<String> items;
  final MiniThemeExtension c;
  const _BulletList({required this.items, required this.c});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items
          .map(
            (item) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6, right: 12),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: MiniColors.danger.withValues(alpha: 0.7),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      item,
                      style: GoogleFonts.outfit(
                        fontSize: 13.5,
                        height: 1.45,
                        fontWeight: FontWeight.w500,
                        color: c.inkSoft,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}
