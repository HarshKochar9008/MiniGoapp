import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/app_reset.dart';
import '../../core/theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../identity/identity_service.dart';
import '../onboarding/onboarding_screen.dart';
import '../qr/qr_widgets.dart';
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
  ThemeMode _themeMode = ThemeController.themeMode.value;
  bool _checkingPush = false;
  PushReadinessResult? _pushReadiness;
  String? _nickname;

  static const _appVersion = 'MiniGo 1.1.0';

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

  void _showQr() {
    HapticFeedback.selectionClick();
    QrCodeSheet.show(context, widget.identity.shortCode);
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    HapticFeedback.selectionClick();
    setState(() => _themeMode = mode);
    await ThemeController.setThemeMode(mode);
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset all local data?'),
        content: const SingleChildScrollView(
          child: Text(
            'This device will forget your short code, onboarding, theme, and '
            'pending uploads, and sign out of your account here.\n\n'
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
              backgroundColor: MiniColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset this app'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await AppReset.clearLocalDataAndRelaunchUi(userId: widget.identity.id);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Preferences',
                      style: MiniText.label.copyWith(color: c.inkSoft)),
                  const SizedBox(height: 4),
                  Text('Settings',
                      style: MiniText.title.copyWith(color: c.ink)),
                ],
              ),
            ),

            // ── Profile ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: _ProfileCard(
                nickname: _nickname,
                shortCode: widget.identity.shortCode,
                onEditName: _editNickname,
                onCopyCode: _copyCode,
                onShowQr: _showQr,
              ),
            ),

            // ── Appearance ─────────────────────────────────────────────
            const _GroupLabel('Appearance'),
            _SettingsGroup(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                  child: _ThemeModePicker(
                    selected: _themeMode,
                    onChanged: _setThemeMode,
                  ),
                ),
              ],
            ),

            // ── Notifications ──────────────────────────────────────────
            const _GroupLabel('Notifications'),
            _SettingsGroup(
              children: [_buildDeliveryTile(c)],
            ),

            // ── About ──────────────────────────────────────────────────
            const _GroupLabel('About'),
            _SettingsGroup(
              children: [
                _SettingsTile(
                  icon: Icons.info_outline_rounded,
                  iconTint: c.accent,
                  label: 'About MiniGo',
                  sub: 'Version, how it works, and legal',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AboutScreen()),
                  ),
                ),
                _SettingsTile(
                  icon: Icons.play_circle_outline_rounded,
                  iconTint: c.accent,
                  label: 'App walkthrough',
                  sub: 'Replay the onboarding walkthrough',
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
                  iconTint: MiniColors.success,
                  label: 'Privacy & Security',
                  sub: 'Encryption, data collection & your rights',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PrivacyScreen()),
                  ),
                ),
              ],
            ),

            // ── Danger zone ────────────────────────────────────────────
            const _GroupLabel('Danger zone'),
            _SettingsGroup(
              children: [
                _SettingsTile(
                  icon: Icons.restart_alt_rounded,
                  iconTint: MiniColors.danger,
                  label: 'Reset local data and sign out',
                  sub: 'Removes local code, settings, and pending transfers.',
                  labelColor: MiniColors.danger,
                  onTap: _confirmFullLocalReset,
                ),
              ],
            ),

            // Footer
            const SizedBox(height: 26),
            Center(
              child: Text(
                _appVersion,
                style: MiniText.small.copyWith(color: c.inkFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Background-delivery health as a quiet, self-explaining tile: a status
  /// dot instead of a loud banner, tap anywhere to re-check.
  Widget _buildDeliveryTile(MiniThemeExtension c) {
    final readiness = _pushReadiness;
    final ready = readiness?.ready == true;
    final tint = _checkingPush
        ? c.inkFaint
        : ready
            ? MiniColors.success
            : MiniColors.warn;
    final status = _checkingPush
        ? 'Checking…'
        : ready
            ? 'Ready — transfers can alert you when the app is closed.'
            : (readiness?.reason ??
                'Push pipeline is not fully configured yet.');

    return InkWell(
      onTap: _checkingPush ? null : _refreshPushReadiness,
      borderRadius: BorderRadius.circular(MiniRadius.card),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(9),
              ),
              child: _checkingPush
                  ? Padding(
                      padding: const EdgeInsets.all(11),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        strokeCap: StrokeCap.round,
                        color: c.inkFaint,
                      ),
                    )
                  : Icon(
                      ready
                          ? Icons.notifications_active_rounded
                          : Icons.notifications_paused_rounded,
                      size: 19,
                      color: tint,
                    ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Background delivery',
                        style: GoogleFonts.outfit(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -0.2,
                          color: c.ink,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: tint,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(status,
                      style: MiniText.small.copyWith(color: c.inkSoft)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.refresh_rounded, size: 18, color: c.inkFaint),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Profile card — identity front and center, with explicit quick actions
// ---------------------------------------------------------------------------

class _ProfileCard extends StatelessWidget {
  final String? nickname;
  final String shortCode;
  final VoidCallback onEditName;
  final VoidCallback onCopyCode;
  final VoidCallback onShowQr;

  const _ProfileCard({
    required this.nickname,
    required this.shortCode,
    required this.onEditName,
    required this.onCopyCode,
    required this.onShowQr,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: miniCard(context, strong: true),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 20),
            child: Column(
              children: [
                Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: 0.13),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      (nickname ?? shortCode).characters.first.toUpperCase(),
                      style: GoogleFonts.outfit(
                        fontSize: 30,
                        fontWeight: FontWeight.w600,
                        color: c.accent,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  nickname ?? 'Add a nickname',
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.outfit(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.5,
                    color: nickname != null ? c.ink : c.inkFaint,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                  decoration: BoxDecoration(
                    color: c.sand,
                    borderRadius: BorderRadius.circular(MiniRadius.pill),
                  ),
                  child: Text(
                    fmtCode(shortCode),
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 13,
                      letterSpacing: 1.6,
                      fontWeight: FontWeight.w500,
                      color: c.inkSoft,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Row(
              children: [
                _ProfileAction(
                  icon: Icons.edit_outlined,
                  label: 'Edit name',
                  onTap: onEditName,
                ),
                const SizedBox(width: 8),
                _ProfileAction(
                  icon: Icons.copy_rounded,
                  label: 'Copy code',
                  onTap: onCopyCode,
                ),
                const SizedBox(width: 8),
                _ProfileAction(
                  icon: Icons.qr_code_rounded,
                  label: 'My QR',
                  onTap: onShowQr,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ProfileAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Expanded(
      child: Material(
        color: c.sand,
        borderRadius: BorderRadius.circular(MiniRadius.control),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MiniRadius.control),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 13),
            child: Column(
              children: [
                Icon(icon, size: 19, color: c.ink),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    height: 1,
                    fontWeight: FontWeight.w500,
                    color: c.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Theme mode picker — Light / Dark / System segmented control
// ---------------------------------------------------------------------------

class _ThemeModePicker extends StatelessWidget {
  final ThemeMode selected;
  final ValueChanged<ThemeMode> onChanged;

  const _ThemeModePicker({required this.selected, required this.onChanged});

  static const _options = [
    (ThemeMode.light, Icons.light_mode_outlined, 'Light'),
    (ThemeMode.dark, Icons.dark_mode_outlined, 'Dark'),
    (ThemeMode.system, Icons.brightness_auto_outlined, 'System'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: c.sand,
        borderRadius: BorderRadius.circular(MiniRadius.pill),
      ),
      child: Row(
        children: [
          for (final (mode, icon, label) in _options)
            Expanded(
              child: _ThemeSegment(
                icon: icon,
                label: label,
                selected: mode == selected,
                onTap: () => onChanged(mode),
              ),
            ),
        ],
      ),
    );
  }
}

class _ThemeSegment extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeSegment({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(MiniRadius.pill),
        boxShadow: selected ? miniCardShadow(context) : const [],
      ),
      child: Material(
        color: selected ? c.paperDeep : Colors.transparent,
        borderRadius: BorderRadius.circular(MiniRadius.pill),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MiniRadius.pill),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: selected ? c.ink : c.inkFaint),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: GoogleFonts.outfit(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? c.ink : c.inkFaint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Nickname sheet
// ---------------------------------------------------------------------------

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
    final c = context.mini;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: c.paperDeep,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MiniRadius.sheet),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 5,
                decoration: BoxDecoration(
                  color: c.sandDeep,
                  borderRadius: BorderRadius.circular(MiniRadius.pill),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text('Nickname', style: MiniText.title.copyWith(color: c.ink)),
            const SizedBox(height: 6),
            Text(
              'Shown on your home screen. Leave empty to remove it.',
              style: MiniText.bodySoft,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: c.ink,
              ),
              decoration: InputDecoration(
                hintText: 'Your nickname',
                hintStyle: GoogleFonts.outfit(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: c.inkFaint,
                ),
                filled: true,
                fillColor: c.sand,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(MiniRadius.control),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 20),
            MiniButton(label: 'Save', onPressed: _save),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Group scaffolding
// ---------------------------------------------------------------------------

class _GroupLabel extends StatelessWidget {
  final String text;
  const _GroupLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 26, 26, 10),
      child: Text(
        text.toUpperCase(),
        style: GoogleFonts.outfit(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.9,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: miniCard(context),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              if (i < children.length - 1) const HairLine(indent: 66),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData? icon;
  final Color? iconTint;
  final String label;
  final String? sub;
  final Color? labelColor;
  final VoidCallback? onTap;

  const _SettingsTile({
    this.icon,
    this.iconTint,
    required this.label,
    this.sub,
    this.labelColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MiniRadius.card),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          children: [
            if (icon != null) ...[
              MiniIconPlate(
                icon: icon!,
                tint: iconTint ?? c.inkSoft,
                size: 40,
                iconSize: 19,
                radius: 9,
              ),
              const SizedBox(width: 13),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.outfit(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.2,
                      color: labelColor ?? c.ink,
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 3),
                    Text(sub!,
                        style: MiniText.small.copyWith(color: c.inkSoft)),
                  ],
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right_rounded, color: c.inkFaint, size: 20),
          ],
        ),
      ),
    );
  }
}
