import 'package:flutter/widgets.dart';

import '../../Minigo/theme/mini_icons.dart';
import '../../core/constants.dart';
import 'app_facts.dart';
import 'update_check.dart';

class ReleaseHighlight {
  final IconData icon;
  final String title;
  final String body;

  const ReleaseHighlight(this.icon, this.title, this.body);
}

/// What changed in one version, as shown in What's New.
class ReleaseNotes {
  final String version;
  final String summary;
  final List<ReleaseHighlight> highlights;

  const ReleaseNotes({
    required this.version,
    required this.summary,
    required this.highlights,
  });

  /// Newest first. Add an entry whenever `version` in pubspec.yaml changes.
  static final List<ReleaseNotes> all = [
    ReleaseNotes(
      version: '1.0.0',
      summary: 'The first release of MiniGo.',
      highlights: [
        ReleaseHighlight(
          MiniIcons.sharingCode,
          'Share with a short code',
          'Give someone your ${AppConstants.codeLength}-character code or QR '
              'code to receive files. No account, email, or phone number '
              'needed.',
        ),
        const ReleaseHighlight(
          MiniIcons.encrypted,
          'End-to-end encryption',
          'Files sent between current versions of MiniGo are encrypted on '
              'the sender’s phone, so only the recipient can open them.',
        ),
        ReleaseHighlight(
          MiniIcons.rooms,
          'Rooms',
          'Share with up to ${AppConstants.maxRoomMembers} people at once. '
              'Rooms close on their own after ${AppFacts.roomLifetimes}.',
        ),
        const ReleaseHighlight(
          MiniIcons.upload,
          'Resume interrupted sends',
          'If your connection drops partway through, pick up where you left '
              'off.',
        ),
        const ReleaseHighlight(
          MiniIcons.systemMode,
          'Light and dark appearance',
          'Choose Light or Dark, or follow your phone’s setting.',
        ),
      ],
    ),
  ];

  /// Notes for [version], or for the newest release before it when this
  /// build has none of its own. Null when nothing applies.
  static ReleaseNotes? forVersion(String? version) {
    if (version == null) return all.isEmpty ? null : all.first;
    for (final notes in all) {
      if (!isNewerVersion(notes.version, version)) return notes;
    }
    return null;
  }
}
