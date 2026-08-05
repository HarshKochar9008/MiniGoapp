import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

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
                        Text('About',
                            style: MiniText.title.copyWith(color: c.ink)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // App identity card
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              clipBehavior: Clip.antiAlias,
              decoration: miniCard(context, strong: true),
              child: Padding(
                padding: const EdgeInsets.all(26),
                child: Column(
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: MiniColors.blue600,
                        borderRadius: BorderRadius.circular(13),
                        boxShadow: [
                          BoxShadow(
                            color: MiniColors.blue600.withValues(alpha: 0.17),
                            blurRadius: 12,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.north_east_rounded,
                        size: 34,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'MiniGo',
                      style: GoogleFonts.outfit(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: c.ink,
                        letterSpacing: -0.6,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: c.sand,
                        borderRadius: BorderRadius.circular(MiniRadius.pill),
                      ),
                      child: Text(
                        'Version 1.1.0',
                        style: MiniText.small.copyWith(
                          color: c.inkSoft,
                          fontWeight: FontWeight.w500,
                          height: 1,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Simple. Fast. Peer-to-peer.',
                      style: MiniText.small.copyWith(color: c.inkFaint),
                    ),
                  ],
                ),
              ),
            ),

            SectionHeader(title: 'What is MiniGo?'),
            _AboutCard(
              child: Text(
                'MiniGo lets you transfer files directly to another person '
                'using a short 6-character code — no accounts, no cloud storage, '
                'no email required. Files are sent peer-to-peer via an encrypted relay.',
                style: GoogleFonts.outfit(
                  fontSize: 14.5,
                  height: 1.55,
                  fontWeight: FontWeight.w400,
                  color: c.inkSoft,
                ),
              ),
            ),

            SectionHeader(title: 'How it works'),
            _AboutCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  _StepRow(
                    step: '1',
                    title: 'Share your code',
                    subtitle:
                        'Give your 6-character code to the person who wants to send you files.',
                    c: c,
                  ),
                  const HairLine(indent: 60),
                  _StepRow(
                    step: '2',
                    title: 'They enter your code',
                    subtitle:
                        'The sender types your code in the Send tab and picks files to upload.',
                    c: c,
                  ),
                  const HairLine(indent: 60),
                  _StepRow(
                    step: '3',
                    title: 'Download instantly',
                    subtitle:
                        'Files appear in your Received tab. Tap to download them to your device.',
                    c: c,
                  ),
                ],
              ),
            ),

            SectionHeader(title: 'Built with'),
            _AboutCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  _InfoRow(label: 'Platform', value: 'Flutter', c: c),
                  const HairLine(indent: 18),
                  _InfoRow(
                      label: 'Backend',
                      value: 'Secure cloud infrastructure',
                      c: c),
                  const HairLine(indent: 18),
                  _InfoRow(
                      label: 'Notifications',
                      value: 'Firebase Cloud Messaging',
                      c: c),
                ],
              ),
            ),

            SectionHeader(title: 'Legal'),
            _AboutCard(
              child: Text(
                '© 2024 MiniGo. All rights reserved.\n\n'
                'MiniGo is provided as-is. We do not store files permanently — '
                'transfers expire after 24 hours. You are responsible for the '
                'content you share.',
                style: GoogleFonts.outfit(
                  fontSize: 13.5,
                  height: 1.55,
                  fontWeight: FontWeight.w400,
                  color: c.inkSoft,
                ),
              ),
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

/// Raised panel wrapper for the About sections.
class _AboutCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const _AboutCard({
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: padding,
      decoration: miniCard(context),
      child: child,
    );
  }
}

class _StepRow extends StatelessWidget {
  final String step;
  final String title;
  final String subtitle;
  final MiniThemeExtension c;
  const _StepRow({
    required this.step,
    required this.title,
    required this.subtitle,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              step,
              style: GoogleFonts.outfit(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.accent,
              ),
            ),
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
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: GoogleFonts.outfit(
                    fontSize: 12.5,
                    height: 1.45,
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

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final MiniThemeExtension c;
  const _InfoRow({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 15, 14, 15),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.outfit(
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
                color: c.ink,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            textAlign: TextAlign.end,
            style: GoogleFonts.outfit(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: c.inkSoft,
            ),
          ),
        ],
      ),
    );
  }
}
