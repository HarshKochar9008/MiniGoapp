import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/app_reset.dart';
import '../../core/theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../identity/identity_service.dart';
import '../onboarding/onboarding_screen.dart';
import '../qr/qr_widgets.dart';
import 'about_screen.dart';
import 'privacy_screen.dart';
import '../../Minigo/theme/mini_icons.dart';

class SettingsScreen extends StatefulWidget {
  final UserIdentity identity;
  const SettingsScreen({super.key, required this.identity});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ThemeMode _themeMode = ThemeController.themeMode.value;
  String? _nickname;
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  @override
  void initState() {
    super.initState();
    _nickname = widget.identity.nickname;
    ThemeController.themeMode.addListener(_syncThemeMode);
  }

  @override
  void dispose() {
    ThemeController.themeMode.removeListener(_syncThemeMode);
    super.dispose();
  }

  /// Appearance can also be reset from Privacy & Security.
  void _syncThemeMode() {
    final mode = ThemeController.themeMode.value;
    if (mode != _themeMode) setState(() => _themeMode = mode);
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

  Future<void> _openNotificationSettings() async {
    final opened = await openAppSettings();
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open app settings')),
      );
    }
  }

  Future<void> _confirmFullLocalReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _ResetAppDialog(),
    );
    if (ok != true || !mounted) return;
    await AppReset.clearLocalDataAndRelaunchUi(userId: widget.identity.id);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Scaffold(
      backgroundColor: c.paper,
      // Scrolls beneath the shell's glass nav, whose height arrives as
      // MediaQuery bottom padding.
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.only(
              bottom: 28 + MediaQuery.paddingOf(context).bottom),
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
              children: [
                _SettingsTile(
                  icon: MiniIcons.notifications,
                  iconTint: c.accent,
                  label: 'App notifications',
                  sub: 'Turn transfer alerts on or off in device settings',
                  onTap: _openNotificationSettings,
                ),
              ],
            ),

            // ── About ──────────────────────────────────────────────────
            const _GroupLabel('About'),
            _SettingsGroup(
              children: [
                _SettingsTile(
                  icon: MiniIcons.info,
                  iconTint: c.accent,
                  label: 'About MiniGo',
                  sub: 'Version, how it works, and legal',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AboutScreen()),
                  ),
                ),
                _SettingsTile(
                  icon: MiniIcons.play,
                  iconTint: c.accent,
                  label: 'App walkthrough',
                  sub: 'Replay the onboarding walkthrough',
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => OnboardingScreen(
                          onComplete: () => Navigator.of(context).pop(),
                        ),
                      ),
                    );
                    // The walkthrough's nickname step may have changed it.
                    final nick =
                        IdentityService.identityNotifier.value?.nickname;
                    if (mounted && nick != _nickname) {
                      setState(() => _nickname = nick);
                    }
                  },
                ),
                _SettingsTile(
                  icon: MiniIcons.shield,
                  iconTint: MiniColors.success,
                  label: 'Privacy & Security',
                  sub: 'Encryption, data collection & your rights',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PrivacyScreen(identity: widget.identity),
                    ),
                  ),
                ),
              ],
            ),

            // ── Danger zone ────────────────────────────────────────────
            const _GroupLabel('Danger zone'),
            _SettingsGroup(
              children: [
                _SettingsTile(
                  icon: MiniIcons.restart,
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
              child: FutureBuilder<PackageInfo>(
                future: _packageInfo,
                builder: (context, snapshot) => Text(
                  snapshot.hasData
                      ? 'MiniGo ${snapshot.data!.version}'
                      : 'MiniGo',
                  style: MiniText.small.copyWith(color: c.inkFaint),
                ),
              ),
            ),
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
                  icon: MiniIcons.edit,
                  label: 'Edit name',
                  onTap: onEditName,
                ),
                const SizedBox(width: 8),
                _ProfileAction(
                  icon: MiniIcons.copy,
                  label: 'Copy code',
                  onTap: onCopyCode,
                ),
                const SizedBox(width: 8),
                _ProfileAction(
                  icon: MiniIcons.qr,
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
    (ThemeMode.light, MiniIcons.lightMode, 'Light'),
    (ThemeMode.dark, MiniIcons.darkMode, 'Dark'),
    (ThemeMode.system, MiniIcons.systemMode, 'System'),
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
              Icon(MiniIcons.chevronRight, color: c.inkFaint, size: 20),
          ],
        ),
      ),
    );
  }
}

/// Confirmation for the full local reset: what gets wiped (files, photos,
/// pending uploads) floats above the bin, then a destructive pill action.
class _ResetAppDialog extends StatelessWidget {
  const _ResetAppDialog();

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _ResetIllustration(),
              const SizedBox(height: 18),
              Text(
                'Reset app data?',
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.5,
                  color: c.ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your saved code, settings, and pending uploads will be '
                'removed on this device, and you’ll be signed out.',
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  fontSize: 15,
                  height: 1.45,
                  color: c.inkSoft,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: MiniButton(
                      label: 'Cancel',
                      style: MiniBtnStyle.secondary,
                      onPressed: () => Navigator.pop(context, false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Material(
                      color: MiniColors.danger,
                      borderRadius: BorderRadius.circular(MiniRadius.pill),
                      child: InkWell(
                        onTap: () => Navigator.pop(context, true),
                        borderRadius: BorderRadius.circular(MiniRadius.pill),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 17),
                          child: Text(
                            'Reset app',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: Colors.white,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResetIllustration extends StatelessWidget {
  const _ResetIllustration();

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final binTint = MiniColors.danger.withValues(alpha: 0.75);

    Widget tile(IconData icon, Color tint, double angle) => Transform.rotate(
          angle: angle,
          child: MiniIconPlate(
            icon: icon,
            tint: tint,
            size: 54,
            iconSize: 24,
            radius: 12,
          ),
        );

    Widget dash(double angle) => Transform.rotate(
          angle: angle,
          child: Container(
            width: 13,
            height: 2.5,
            decoration: BoxDecoration(
              color: binTint,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );

    return SizedBox(
      width: 190,
      height: 132,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
              left: 8, top: 22, child: tile(MiniIcons.file, c.accent, -0.22)),
          Positioned(top: 0, child: tile(MiniIcons.image, c.accent, 0)),
          Positioned(
            right: 8,
            top: 22,
            child: tile(MiniIcons.upload, MiniColors.danger, 0.22),
          ),
          Positioned(
            bottom: 0,
            child: Icon(MiniIcons.delete, size: 66, color: binTint),
          ),
          // Motion ticks either side of the bin.
          Positioned(left: 42, bottom: 30, child: dash(0.35)),
          Positioned(left: 40, bottom: 18, child: dash(-0.2)),
          Positioned(right: 42, bottom: 30, child: dash(-0.35)),
          Positioned(right: 40, bottom: 18, child: dash(0.2)),
        ],
      ),
    );
  }
}
