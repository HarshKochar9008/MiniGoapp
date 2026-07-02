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
  String? _nickname;

  @override
  void initState() {
    super.initState();
    _nickname = widget.identity.nickname;
    _refreshPushReadiness();
  }

  Future<void> _editNickname() async {
    HapticFeedback.selectionClick();
    final result = await _NicknameSheet.show(context, _nickname);
    if (result == null || !mounted) return;
    final newNick = result.value;
    await IdentityService.setNickname(newNick);
    if (!mounted) return;
    setState(() => _nickname = newNick);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(newNick == null ? 'Nickname removed' : 'Nickname saved'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _copyCode() {
    Clipboard.setData(ClipboardData(text: widget.identity.shortCode));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Code copied')),
    );
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
            child: const Text('Reset this app'),
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
          padding: const EdgeInsets.only(bottom: 32),
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

            // Profile card
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: c.paperDeep,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(
                        color: ZenColors.blue50,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          (_nickname ?? widget.identity.shortCode)
                              .characters
                              .first
                              .toUpperCase(),
                          style: GoogleFonts.outfit(
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                            color: ZenColors.blue600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _nickname ?? 'Add a nickname',
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: _nickname != null ? c.ink : c.inkFaint,
                            ),
                          ),
                          const SizedBox(height: 3),
                          GestureDetector(
                            onTap: _copyCode,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  fmtCode(widget.identity.shortCode),
                                  style: GoogleFonts.jetBrainsMono(
                                    fontSize: 13,
                                    letterSpacing: 2,
                                    color: c.inkSoft,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Icon(Icons.copy_rounded,
                                    size: 13, color: c.inkFaint),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.edit_outlined,
                          size: 20, color: c.inkSoft),
                      tooltip: 'Edit nickname',
                      onPressed: _editNickname,
                    ),
                  ],
                ),
              ),
            ),

            // Delivery status card
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: _buildPushCard(c),
            ),

            _GroupLabel('Preferences'),
            _SettingsGroup(
              children: [
                _SettingsTile(
                  icon: Icons.dark_mode_outlined,
                  iconTint: ZenColors.blue600,
                  label: 'Dark mode',
                  sub: 'Switch between light and dark theme',
                  trailing: Switch.adaptive(
                    value: _darkMode,
                    onChanged: _setDarkMode,
                  ),
                ),
              ],
            ),

            _GroupLabel('About'),
            _SettingsGroup(
              children: [
                _SettingsTile(
                  icon: Icons.info_outline_rounded,
                  iconTint: ZenColors.blue600,
                  label: 'About MiniGo',
                  sub: 'Version, how it works, and legal',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AboutScreen()),
                  ),
                ),
                _SettingsTile(
                  icon: Icons.play_circle_outline_rounded,
                  iconTint: ZenColors.blue600,
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
                _SettingsTile(
                  icon: Icons.shield_outlined,
                  iconTint: ZenColors.success,
                  label: 'Privacy & Security',
                  sub: 'Encryption, data collection & your rights',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PrivacyScreen()),
                  ),
                ),
                _SettingsTile(
                  icon: Icons.tag_rounded,
                  iconTint: ZenColors.inkFaint,
                  label: 'Version',
                  trailingText: 'MiniGo 1.1.0',
                ),
              ],
            ),

            _GroupLabel('Danger zone'),
            _SettingsGroup(
              children: [
                _SettingsTile(
                  icon: Icons.delete_outline_rounded,
                  iconTint: ZenColors.danger,
                  label: 'Clear all local data & sign out',
                  sub: 'Removes your code and settings from this device',
                  labelColor: ZenColors.danger,
                  onTap: _confirmFullLocalReset,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPushCard(ZenThemeExtension c) {
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

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tint.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: tint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: tint,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    height: 1.4,
                    color: c.inkSoft,
                  ),
                ),
              ],
            ),
          ),
          if (!_checkingPush)
            IconButton(
              icon: Icon(Icons.refresh_rounded, size: 18, color: c.inkFaint),
              tooltip: 'Re-check',
              onPressed: _refreshPushReadiness,
            ),
        ],
      ),
    );
  }
}

/// Nullable-result wrapper so "cancelled" (null) and "removed nickname"
/// (value: null) can be told apart.
class _NicknameResult {
  final String? value;
  const _NicknameResult(this.value);
}

class _NicknameSheet extends StatefulWidget {
  final String? current;
  const _NicknameSheet({this.current});

  static Future<_NicknameResult?> show(BuildContext context, String? current) {
    return showModalBottomSheet<_NicknameResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NicknameSheet(current: current),
    );
  }

  @override
  State<_NicknameSheet> createState() => _NicknameSheetState();
}

class _NicknameSheetState extends State<_NicknameSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.current ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final trimmed = _controller.text.trim();
    Navigator.pop(
      context,
      _NicknameResult(trimmed.isEmpty ? null : trimmed),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: c.paper,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: c.divider,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('Nickname', style: ZenText.title.copyWith(color: c.ink)),
            const SizedBox(height: 4),
            Text(
              'Shown on your home screen. Leave empty to remove it.',
              style: ZenText.small,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              style: GoogleFonts.outfit(fontSize: 16, color: c.ink),
              decoration: InputDecoration(
                hintText: 'Your nickname',
                hintStyle:
                    GoogleFonts.outfit(fontSize: 16, color: c.inkFaint),
                filled: true,
                fillColor: c.paperDeep,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            ZenButton(label: 'Save', onPressed: _save),
          ],
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  final String text;
  const _GroupLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
      child: Text(
        text.toUpperCase(),
        style: GoogleFonts.outfit(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
          color: c.inkFaint,
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: c.paperDeep,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              if (i < children.length - 1) const HairLine(indent: 60),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color iconTint;
  final String label;
  final String? sub;
  final String? trailingText;
  final Widget? trailing;
  final Color? labelColor;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.icon,
    required this.iconTint,
    required this.label,
    this.sub,
    this.trailingText,
    this.trailing,
    this.labelColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: iconTint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: iconTint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.outfit(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: labelColor ?? c.ink,
                    ),
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
              trailing!
            else if (trailingText != null)
              Text(trailingText!,
                  style: ZenText.small.copyWith(color: c.inkSoft))
            else if (onTap != null)
              Icon(Icons.chevron_right_rounded, color: c.inkFaint, size: 20),
          ],
        ),
      ),
    );
  }
}
