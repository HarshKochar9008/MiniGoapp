import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../zensend/theme/zen_theme.dart';
import '../../zensend/widgets/zen_widgets.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: ListView(
          children: [
            // Header with back button
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 20, 6),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_rounded, color: c.ink),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Whoosh',
                            style: ZenText.label.copyWith(color: c.inkSoft)),
                        const SizedBox(height: 4),
                        Text('Privacy & Security',
                            style: ZenText.title.copyWith(color: c.ink)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const HairLine(indent: 20),
            const SizedBox(height: 8),

            // Summary banner
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: ZenColors.success.withOpacity(0.08),
                border: Border.all(color: ZenColors.success.withOpacity(0.2)),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline_rounded,
                      size: 20, color: ZenColors.success),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Whoosh is designed to minimise data collection. '
                      'No accounts. No permanent storage. No tracking.',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        height: 1.5,
                        color: ZenColors.success,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            SectionHeader(title: 'Data we collect'),
            const HairLine(indent: 20),
            _PolicySection(
              icon: Icons.fingerprint_rounded,
              title: 'Anonymous device identity',
              body:
                  'When you first open Whoosh, a random 6-character code and anonymous '
                  'user ID are generated on your device and stored in Supabase. No name, '
                  'email, or phone number is ever collected.',
              c: c,
            ),
            const HairLine(indent: 20),
            _PolicySection(
              icon: Icons.upload_file_rounded,
              title: 'Temporary file storage',
              body:
                  'Files you send are uploaded to Supabase Storage for delivery only. '
                  'They are automatically deleted after 24 hours. We do not read, scan, '
                  'or process the contents of your files.',
              c: c,
            ),
            const HairLine(indent: 20),
            _PolicySection(
              icon: Icons.notifications_outlined,
              title: 'Push notification token',
              body:
                  'If you enable push notifications, a Firebase Cloud Messaging (FCM) '
                  'token is stored alongside your user ID so that incoming-transfer alerts '
                  'can be delivered. This token contains no personal information.',
              c: c,
            ),
            const HairLine(indent: 20),

            SectionHeader(title: 'What we do NOT collect'),
            const HairLine(indent: 20),
            _BulletList(
              items: const [
                'Your name, email address, or phone number',
                'Location data or device identifiers',
                'Browsing history or analytics events',
                'File contents — only binary chunks for delivery',
              ],
              c: c,
            ),
            const HairLine(indent: 20),

            SectionHeader(title: 'Security'),
            const HairLine(indent: 20),
            _PolicySection(
              icon: Icons.https_rounded,
              title: 'Encrypted in transit',
              body:
                  'All communication between the app and Supabase uses HTTPS/TLS. '
                  'Files are transferred over encrypted connections.',
              c: c,
            ),
            const HairLine(indent: 20),
            _PolicySection(
              icon: Icons.timer_outlined,
              title: 'Short-lived transfers',
              body:
                  'Transfers expire after 24 hours. After expiry, files are removed '
                  'from storage and the transfer record is marked expired.',
              c: c,
            ),
            const HairLine(indent: 20),
            _PolicySection(
              icon: Icons.code_rounded,
              title: 'Code-based sharing',
              body:
                  'Files can only be received by the person who knows your code. '
                  'There is no public listing of users or codes.',
              c: c,
            ),
            const HairLine(indent: 20),

            SectionHeader(title: 'Your rights'),
            const HairLine(indent: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: Text(
                'You can delete all local data at any time using "Clear all local data & '
                'sign out" in Settings. This removes your code, identity, and queued transfers '
                'from this device and signs you out of the backend.',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  height: 1.6,
                  color: c.inkSoft,
                ),
              ),
            ),
            const HairLine(indent: 20),

            SectionHeader(title: 'Contact'),
            const HairLine(indent: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: Text(
                'For privacy questions or data removal requests, '
                'contact the developer through the app store listing.',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  height: 1.6,
                  color: c.inkSoft,
                ),
              ),
            ),
            const HairLine(indent: 20),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class _PolicySection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final ZenThemeExtension c;
  const _PolicySection({
    required this.icon,
    required this.title,
    required this.body,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: c.sand,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: c.inkSoft),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: GoogleFonts.inter(
                    fontSize: 13,
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
  final ZenThemeExtension c;
  const _BulletList({required this.items, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: items
            .map(
              (item) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 10),
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          color: c.inkFaint,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        item,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          height: 1.5,
                          color: c.inkSoft,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}
