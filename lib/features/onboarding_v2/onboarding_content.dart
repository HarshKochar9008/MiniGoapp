import 'package:flutter/material.dart';

import '../../Minigo/theme/mini_icons.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../core/constants.dart';
import '../settings/app_facts.dart';

/// Every word and option the questionnaire onboarding shows, in one place.
///
/// Claims here must stay true: the numbers come from [AppConstants] /
/// [AppFacts], so they move with the real limits.

/// Flip to true only once the `expire-transfers` pg_cron job is confirmed live
/// in the Supabase dashboard — it is what actually deletes files at 24 h.
/// Until then the copy says transfers *expire* (always true: the app filters
/// on the TTL) rather than that files are *deleted*.
const bool kExpiryDeletesFiles = false;

// ---------------------------------------------------------------------------
// Pains (named by the swipe cards) and the fixes that answer them
// ---------------------------------------------------------------------------

enum OnbPain {
  airdrop,
  swapNumbers,
  emailLinks,
  groupChat,
  staysOnline,
  whoCanSee,
  signUp,
}

class OnbPainOption {
  final OnbPain pain;

  /// The short bold line on the solution screen.
  final String headline;
  final IconData icon;
  const OnbPainOption(this.pain, this.headline, this.icon);

  /// The soft line under [headline]. Every one is a true statement about the
  /// app as built.
  String get fix => switch (pain) {
        OnbPain.airdrop => 'iPhone or Android — one code, both ways.',
        OnbPain.swapNumbers => 'Your code reveals nothing about you.',
        OnbPain.emailLinks => 'Up to ${AppFacts.maxFiles} files at once, '
            '${AppFacts.maxFileSize} each.',
        OnbPain.groupChat => 'Up to ${AppConstants.maxRoomMembers} people. '
            'Closes on its own.',
        OnbPain.staysOnline => kExpiryDeletesFiles
            ? 'Files are deleted after ${AppFacts.transferLifetime}.'
            : 'Transfers expire after ${AppFacts.transferLifetime}.',
        OnbPain.whoCanSee => 'Only the person you send to can open it.',
        OnbPain.signUp => 'Your code is ready in seconds.',
      };
}

const onbPainOptions = [
  OnbPainOption(OnbPain.airdrop, 'Any phone works', MiniIcons.device),
  OnbPainOption(
      OnbPain.swapNumbers, 'No numbers to swap', MiniIcons.sharingCode),
  OnbPainOption(OnbPain.emailLinks, 'Straight to their phone', MiniIcons.send),
  OnbPainOption(OnbPain.groupChat, 'Rooms for groups', MiniIcons.rooms),
  OnbPainOption(OnbPain.staysOnline, 'Short-lived by design', MiniIcons.timer),
  OnbPainOption(OnbPain.whoCanSee, 'End-to-end encrypted', MiniIcons.encrypted),
  OnbPainOption(OnbPain.signUp, 'No account needed', MiniIcons.account),
];

OnbPainOption onbPainOption(OnbPain pain) =>
    onbPainOptions.firstWhere((o) => o.pain == pain);

/// Order the solution screen lists pains in, and backfills from.
const onbPainOrder = OnbPain.values;

// ---------------------------------------------------------------------------
// Swipe cards (screen 2)
// ---------------------------------------------------------------------------

class OnbStatement {
  final String text;

  /// Agreeing counts as picking this pain for the solution screen.
  final OnbPain pain;
  const OnbStatement(this.text, this.pain);
}

const onbStatements = [
  OnbStatement('I’ve given my number to a stranger just to get one photo.',
      OnbPain.swapNumbers),
  OnbStatement(
      'My friend has an Android, so AirDrop is useless.', OnbPain.airdrop),
  OnbStatement(
      'I made a group chat just to share trip photos — and I’m still in it.',
      OnbPain.groupChat),
  OnbStatement(
      'I’ve uploaded something to a drive just so one person could download it.',
      OnbPain.emailLinks),
];

// ---------------------------------------------------------------------------
// Share card (screens 4, 6, 7)
// ---------------------------------------------------------------------------

/// A card colourway. Fixed colours (not theme tokens): the card is exported as
/// an image and must look the same wherever it lands. Every tone stays inside
/// the Mini palette — neutrals and the one blue — per mini_theme.dart.
class OnbCardTone {
  final String name;
  final List<Color> background;
  final Color ink;
  final Color inkSoft;
  final Color accent;

  const OnbCardTone({
    required this.name,
    required this.background,
    required this.ink,
    required this.inkSoft,
    required this.accent,
  });

  static OnbCardTone lerp(OnbCardTone a, OnbCardTone b, double t) {
    final n = a.background.length > b.background.length
        ? a.background.length
        : b.background.length;
    Color at(List<Color> l, int i) => l[i < l.length ? i : l.length - 1];
    return OnbCardTone(
      name: t < 0.5 ? a.name : b.name,
      background: [
        for (var i = 0; i < n; i++)
          Color.lerp(at(a.background, i), at(b.background, i), t)!,
      ],
      ink: Color.lerp(a.ink, b.ink, t)!,
      inkSoft: Color.lerp(a.inkSoft, b.inkSoft, t)!,
      accent: Color.lerp(a.accent, b.accent, t)!,
    );
  }
}

const onbCardTones = [
  OnbCardTone(
    name: 'Blue',
    background: [MiniColors.blue600, MiniColors.blue500],
    ink: Colors.white,
    inkSoft: Color(0xD9FFFFFF),
    accent: MiniColors.blue200,
  ),
  OnbCardTone(
    name: 'Midnight',
    background: [Color(0xFF15151C), MiniColors.ink],
    ink: Colors.white,
    inkSoft: Color(0xB3FFFFFF),
    accent: MiniColors.blue500,
  ),
  OnbCardTone(
    name: 'Nebula',
    background: [MiniColors.blue600, Color(0xFF1A2466), MiniColors.ink],
    ink: Colors.white,
    inkSoft: Color(0xC7FFFFFF),
    accent: MiniColors.blue200,
  ),
  OnbCardTone(
    name: 'Sky',
    background: [MiniColors.blue50, MiniColors.blue200],
    ink: MiniColors.ink,
    inkSoft: Color(0xFF3A3A48),
    accent: MiniColors.blue600,
  ),
  OnbCardTone(
    name: 'Cloud',
    background: [Colors.white, MiniColors.paper],
    ink: MiniColors.ink,
    inkSoft: MiniColors.inkSoft,
    accent: MiniColors.blue600,
  ),
];

const onbCardLines = [
  'Send me files',
  'Drop files here',
  'Beam me something 🛸',
];

/// Text that goes with a shared personal card. The link is the same https QR
/// link the app already uses: it opens MiniGo's Send screen with this code
/// filled in, or shows install instructions when MiniGo isn't installed.
String onbPersonalShareText(String code) =>
    'Send me files on MiniGo 🛸 My code: ${_dash(code)}\n'
    '${AppConstants.qrPayloadForCode(code)}';

String _dash(String code) =>
    code.length == 6 ? '${code.substring(0, 3)}-${code.substring(3)}' : code;

// ---------------------------------------------------------------------------
// Placeholder Pro paywall (screen 8) — DEBUG BUILDS ONLY
// ---------------------------------------------------------------------------

class OnbProPerk {
  final IconData icon;
  final String pro;
  final String free;
  const OnbProPerk(this.icon, this.pro, this.free);
}

// TODO(pro): every bracketed number is a placeholder. Replace with what Pro
// will actually ship before this screen leaves debug builds.
final onbProPerks = [
  OnbProPerk(
      MiniIcons.upload, 'Files up to [2 GB]', 'free: ${AppFacts.maxFileSize}'),
  OnbProPerk(MiniIcons.timer, 'Files last [7 days]',
      'free: ${AppFacts.transferLifetime}'),
  OnbProPerk(
      MiniIcons.rooms,
      'Rooms for up to [50] people, open up to [24 h]',
      'free: ${AppConstants.maxRoomMembers} people, '
          '${AppConstants.roomLifetimeMinutesOptions.last ~/ 60} h'),
  OnbProPerk(
      MiniIcons.file, '[100] files per send', 'free: ${AppFacts.maxFiles}'),
];

// TODO(pro): placeholder pricing — wire to real store products.
const onbProTrialLabel = '[7-day]';
const onbProYearlyPrice = '[\$19.99/yr]';
const onbProYearlyPerMonth = 'about \$1.67/mo';
const onbProMonthlyPrice = '[\$2.99/mo]';
const onbProYearlyRenewal = '[\$19.99]';
