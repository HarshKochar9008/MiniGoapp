import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../zensend/theme/zen_theme.dart';
import '../../zensend/widgets/zen_widgets.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

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
                        Text('About', style: ZenText.title.copyWith(color: c.ink)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const HairLine(indent: 20),
            const SizedBox(height: 8),

            // App identity card
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: c.paperDeep,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: ZenColors.blue600,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.north_east_rounded,
                      size: 32,
                      color: ZenColors.paper,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Whoosh',
                    style: GoogleFonts.instrumentSerif(
                      fontSize: 22,
                      color: c.ink,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Version 1.1.0',
                    style: ZenText.small.copyWith(color: c.inkSoft),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Simple. Fast. Peer-to-peer.',
                    style: ZenText.small.copyWith(color: c.inkFaint),
                  ),
                ],
              ),
            ),

            SectionHeader(title: 'What is Whoosh?'),
            const HairLine(indent: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: Text(
                'Whoosh lets you transfer files directly to another person '
                'using a short 6-character code — no accounts, no cloud storage, '
                'no email required. Files are sent peer-to-peer via an encrypted relay.',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  height: 1.6,
                  color: c.inkSoft,
                ),
              ),
            ),
            const HairLine(indent: 20),

            SectionHeader(title: 'How it works'),
            const HairLine(indent: 20),
            _StepRow(
              step: '1',
              title: 'Share your code',
              subtitle: 'Give your 6-character code to the person who wants to send you files.',
              c: c,
            ),
            const HairLine(indent: 72),
            _StepRow(
              step: '2',
              title: 'They enter your code',
              subtitle: 'The sender types your code in the Send tab and picks files to upload.',
              c: c,
            ),
            const HairLine(indent: 72),
            _StepRow(
              step: '3',
              title: 'Download instantly',
              subtitle: 'Files appear in your Received tab. Tap to download them to your device.',
              c: c,
            ),
            const HairLine(indent: 20),

            SectionHeader(title: 'Built with'),
            const HairLine(indent: 20),
            _InfoRow(label: 'Platform', value: 'Flutter', c: c),
            const HairLine(indent: 20),
            _InfoRow(label: 'Backend', value: 'Supabase', c: c),
            const HairLine(indent: 20),
            _InfoRow(label: 'Notifications', value: 'Firebase Cloud Messaging', c: c),
            const HairLine(indent: 20),

            SectionHeader(title: 'Legal'),
            const HairLine(indent: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: Text(
                '© 2024 Whoosh. All rights reserved.\n\n'
                'Whoosh is provided as-is. We do not store files permanently — '
                'transfers expire after 24 hours. You are responsible for the '
                'content you share.',
                style: GoogleFonts.inter(
                  fontSize: 13,
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

class _StepRow extends StatelessWidget {
  final String step;
  final String title;
  final String subtitle;
  final ZenThemeExtension c;
  const _StepRow({
    required this.step,
    required this.title,
    required this.subtitle,
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
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: ZenColors.blue600.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              step,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: ZenColors.blue600,
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
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 12,
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

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final ZenThemeExtension c;
  const _InfoRow({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: GoogleFonts.inter(fontSize: 14, color: c.ink)),
          ),
          Text(value,
              style: GoogleFonts.inter(fontSize: 13, color: c.inkSoft)),
        ],
      ),
    );
  }
}
