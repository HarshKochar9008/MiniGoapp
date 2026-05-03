import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/app_reset.dart';
import '../../core/theme.dart';
import '../../zensend/widgets/zen_widgets.dart';
import '../identity/identity_service.dart';
import '../onboarding/onboarding_screen.dart';
import '../transfer/transfer_service.dart';
import 'about_screen.dart';
import 'privacy_screen.dart';

class SettingsScreen extends StatefulWidget {
  final UserIdentity identity;
  const SettingsScreen({super.key, required this.identity});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _darkMode = ThemeController.themeMode.value == ThemeMode.dark;
  bool _checkingPush = false;
  PushReadinessResult? _pushReadiness;

  @override
  void initState() {
    super.initState();
    _refreshPushReadiness();
  }

  Future<void> _setDarkMode(bool enabled) async {
    setState(() => _darkMode = enabled);
    await ThemeController.setThemeMode(
      enabled ? ThemeMode.dark : ThemeMode.light,
    );
  }

  Future<void> _refreshPushReadiness() async {
    setState(() => _checkingPush = true);
    final result = await TransferService.verifyClosedAppDeliveryReadiness(
      receiverId: widget.identity.id,
    );
    if (!mounted) return;
    setState(() {
      _pushReadiness = result;
      _checkingPush = false;
    });
  }

  Future<void> _confirmFullLocalReset() async {
    final c = context.zen;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset all local data?'),
        content: const SingleChildScrollView(
          child: Text(
            'This device will forget your short code, onboarding, theme, and '
            'pending uploads, and sign out of Supabase here.\n\n'
            'Network issues are not fixed by a reset.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: ZenColors.danger,
              foregroundColor: c.paper,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset this device'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await AppReset.clearLocalDataAndRelaunchUi();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: ListView(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Preferences',
                      style: ZenText.label.copyWith(color: c.inkSoft)),
                  const SizedBox(height: 4),
                  Text('Settings',
                      style: ZenText.title.copyWith(color: c.ink)),
                ],
              ),
            ),
            const HairLine(indent: 20),
            const SizedBox(height: 8),

            // Identity card
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: c.paperDeep,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  Text('Your code',
                      style: ZenText.label.copyWith(color: c.inkSoft)),
                  const SizedBox(height: 14),
                  Text(
                    fmtCode(widget.identity.shortCode),
                    style: ZenText.codeLarge.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _CodeAction(
                        icon: Icons.copy_rounded,
                        label: 'Copy',
                        onTap: () {
                          Clipboard.setData(ClipboardData(
                              text: widget.identity.shortCode));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Code copied')),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Push readiness
            _buildPushCard(),

            SectionHeader(title: 'Preferences'),
            const HairLine(indent: 20),

            _ToggleRow(
              label: 'Dark mode',
              sub: 'Switch between light and dark theme',
              value: _darkMode,
              onChanged: _setDarkMode,
            ),
            const HairLine(indent: 20),

            SectionHeader(title: 'About'),
            const HairLine(indent: 20),

            _LinkRow(
              label: 'About Whoosh',
              sub: 'Version, how it works, and legal',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AboutScreen()),
              ),
            ),
            const HairLine(indent: 20),
            _LinkRow(
              label: 'How it works',
              sub: 'View the app walkthrough again',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => OnboardingScreen(
                    onComplete: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ),
            const HairLine(indent: 20),
            _LinkRow(
              label: 'Privacy & Security',
              sub: 'Encryption, data collection & your rights',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PrivacyScreen()),
              ),
            ),
            const HairLine(indent: 20),
            _LinkRow(
              label: 'Version',
              trailing: 'Whoosh 1.1.0',
            ),
            const HairLine(indent: 20),

            const SizedBox(height: 32),

            // Danger zone
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
              child: ZenButton(
                label: 'Clear all local data & sign out',
                style: ZenBtnStyle.danger,
                leading: const Icon(Icons.delete_outline_rounded,
                    size: 16, color: ZenColors.danger),
                onPressed: _confirmFullLocalReset,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPushCard() {
    final readiness = _pushReadiness;
    final ready = readiness?.ready == true;
    final tint = _checkingPush
        ? ZenColors.blue600
        : ready
            ? ZenColors.success
            : ZenColors.warn;
    final icon = _checkingPush
        ? Icons.sync_rounded
        : ready
            ? Icons.verified_rounded
            : Icons.warning_amber_rounded;
    final title = _checkingPush
        ? 'Checking push diagnostics…'
        : ready
            ? 'Closed-app delivery ready'
            : 'Closed-app delivery not ready';
    final subtitle = _checkingPush
        ? 'Verifying token and push relay health'
        : ready
            ? 'Incoming transfers can alert you when the app is closed.'
            : (readiness?.reason ??
                'Push pipeline is not fully configured yet.');

    return StatusBanner(
      icon: icon,
      text: '$title\n$subtitle',
      tint: tint,
      onTap: _checkingPush ? null : _refreshPushReadiness,
    );
  }
}

class _CodeAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _CodeAction(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: c.paper,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: c.ink),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: c.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final String sub;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow(
      {required this.label,
      required this.sub,
      required this.value,
      required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: c.ink,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(sub,
                    style: ZenText.small.copyWith(color: c.inkSoft)),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  final String label;
  final String? sub;
  final String? trailing;
  final VoidCallback? onTap;
  const _LinkRow(
      {required this.label, this.sub, this.trailing, this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.inter(
                        fontSize: 14, color: c.ink),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(sub!,
                        style: ZenText.small.copyWith(color: c.inkSoft)),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              Text(trailing!,
                  style: ZenText.small.copyWith(color: c.inkSoft))
            else if (onTap != null)
              Icon(Icons.chevron_right_rounded,
                  color: c.inkFaint, size: 20),
          ],
        ),
      ),
    );
  }
}
