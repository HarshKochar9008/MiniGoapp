import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../Minigo/theme/mini_icons.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../../core/network/connection_status.dart';

// ---------------------------------------------------------------------------
// Page scaffolding
// ---------------------------------------------------------------------------

/// A settings sub-page: recessed background, back button beside a breadcrumb
/// and title, then a scrolling column of sections. On tablets the column keeps
/// a readable width instead of stretching edge to edge.
class MiniSettingsPage extends StatelessWidget {
  final String title;
  final String eyebrow;
  final List<Widget> children;

  const MiniSettingsPage({
    super.key,
    required this.title,
    this.eyebrow = 'Settings',
    required this.children,
  });

  static const _maxContentWidth = 640.0;

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = ((constraints.maxWidth - _maxContentWidth) / 2)
                .clamp(0.0, double.infinity);
            return ListView(
              padding: EdgeInsets.fromLTRB(side, 0, side, 36 + bottomInset),
              children: [
                MiniSettingsHeader(title: title, eyebrow: eyebrow),
                ...children,
              ],
            );
          },
        ),
      ),
    );
  }
}

class MiniSettingsHeader extends StatelessWidget {
  final String title;
  final String eyebrow;

  const MiniSettingsHeader({
    super.key,
    required this.title,
    this.eyebrow = 'Settings',
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 20, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () => Navigator.maybePop(context),
            style: IconButton.styleFrom(
              backgroundColor: c.sand,
              foregroundColor: c.ink,
              fixedSize: const Size.square(40),
            ),
            icon: const Icon(MiniIcons.back, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              header: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    eyebrow,
                    style: MiniText.label.copyWith(color: c.inkSoft),
                  ),
                  const SizedBox(height: 4),
                  Text(title, style: MiniText.title.copyWith(color: c.ink)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Grouped card of rows under a small caps label, with an optional footnote.
/// Rows are separated by hairlines that start where the row text does.
class MiniSettingsSection extends StatelessWidget {
  final String? title;
  final String? footer;
  final List<Widget> children;

  const MiniSettingsSection({
    super.key,
    this.title,
    this.footer,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 26, 26, 10),
            child: Semantics(
              header: true,
              child: Text(
                title!.toUpperCase(),
                style: MiniText.label.copyWith(
                  color: c.inkSoft,
                  letterSpacing: 0.9,
                ),
              ),
            ),
          )
        else
          const SizedBox(height: 16),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          clipBehavior: Clip.antiAlias,
          decoration: miniCard(context),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i < children.length - 1)
                  const HairLine(indent: MiniSettingsRow.textInset),
              ],
            ],
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 10, 26, 0),
            child: Text(
              footer!,
              style: MiniText.small.copyWith(color: c.inkSoft, height: 1.45),
            ),
          ),
      ],
    );
  }
}

/// What sits at the trailing edge of a tappable row.
enum MiniRowAccessory {
  /// Chevron when the row has an [MiniSettingsRow.onTap], nothing otherwise.
  auto,
  chevron,

  /// The action leaves the app (browser, mail, store).
  external,
  none,
}

/// One settings row: icon plate, title with optional subtitle, an optional
/// trailing value, and an accessory showing what a tap does.
///
/// The app theme turns ink splashes off globally, so rows draw their own
/// pressed highlight — a faint wash, like a native settings list.
class MiniSettingsRow extends StatelessWidget {
  /// Where row text starts; hairlines between rows indent to match.
  static const textInset = 64.0;

  final IconData icon;
  final String title;
  final String? subtitle;

  /// Short trailing fact ("24 hours", "This device").
  final String? value;
  final Color? valueColor;

  /// Replaces [value] — e.g. a skeleton while the value loads.
  final Widget? trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final MiniRowAccessory accessory;
  final bool destructive;

  /// Shows a spinner in place of the accessory and ignores taps.
  final bool busy;

  /// Dims the row and ignores taps.
  final bool enabled;

  const MiniSettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.valueColor,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.accessory = MiniRowAccessory.auto,
    this.destructive = false,
    this.busy = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final interactive = enabled && !busy;
    final tint = destructive ? MiniColors.danger : c.inkSoft;
    final resolvedAccessory = accessory == MiniRowAccessory.auto
        ? (onTap != null ? MiniRowAccessory.chevron : MiniRowAccessory.none)
        : accessory;

    final trailingContent = trailing ??
        (value == null
            ? null
            : Text(
                value!,
                textAlign: TextAlign.end,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                  color: valueColor ?? c.inkSoft,
                ),
              ));

    final row = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            MiniIconPlate(
              icon: icon,
              tint: tint,
              size: 36,
              iconSize: 18,
              radius: 9,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.outfit(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.2,
                      height: 1.25,
                      color: destructive ? MiniColors.danger : c.ink,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      style: MiniText.small.copyWith(color: c.inkSoft),
                    ),
                  ],
                ],
              ),
            ),
            if (trailingContent != null) ...[
              const SizedBox(width: 12),
              ConstrainedBox(
                // Keeps a long value from squeezing the title on small phones.
                constraints:
                    BoxConstraints(maxWidth: constraints.maxWidth * 0.4),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: KeyedSubtree(
                    key: ValueKey<Object?>(value ?? trailing.runtimeType),
                    child: trailingContent,
                  ),
                ),
              ),
            ],
            if (busy) ...[
              const SizedBox(width: 10),
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ] else if (resolvedAccessory == MiniRowAccessory.chevron) ...[
              const SizedBox(width: 6),
              Icon(MiniIcons.chevronRight, size: 18, color: c.inkFaint),
            ] else if (resolvedAccessory == MiniRowAccessory.external) ...[
              const SizedBox(width: 6),
              Icon(MiniIcons.externalLink, size: 17, color: c.inkFaint),
            ],
          ],
        ),
      ),
    );

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: MergeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: interactive ? onTap : null,
            onLongPress: interactive ? onLongPress : null,
            splashFactory: NoSplash.splashFactory,
            highlightColor:
                c.ink.withValues(alpha: context.isDarkMini ? 0.07 : 0.045),
            child: Semantics(
              button: onTap != null,
              enabled: interactive,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: row,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder for a row value that is still loading.
class MiniValueSkeleton extends StatelessWidget {
  final double width;
  const MiniValueSkeleton({super.key, this.width = 54});

  @override
  Widget build(BuildContext context) => MiniSkeleton(width: width, height: 12);
}

/// Icon-led one-liner for short assurances inside a card.
class MiniFactLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? tint;

  const MiniFactLine({
    super.key,
    required this.icon,
    required this.text,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 17, color: tint ?? c.inkSoft),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.outfit(
              fontSize: 14,
              height: 1.4,
              color: c.ink,
            ),
          ),
        ),
      ],
    );
  }
}

void showMiniSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

// ---------------------------------------------------------------------------
// Sheets
// ---------------------------------------------------------------------------

/// Opens a modal sheet styled by the app's bottom sheet theme. [builder]
/// should return a [MiniSheetFrame].
Future<T?> showMiniSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: builder,
  );
}

/// Drag handle, padding and scrolling for sheet content.
///
/// [footer] holds the sheet's actions and stays in view while [child]
/// scrolls, so Cancel is never below the fold on a short phone.
///
/// [locked] swallows vertical drags while an action runs: the sheet's own
/// drag-to-dismiss pops the route directly, ignoring any [PopScope].
class MiniSheetFrame extends StatelessWidget {
  final Widget child;
  final Widget? footer;
  final bool locked;

  const MiniSheetFrame({
    super.key,
    required this.child,
    this.footer,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final footer = this.footer;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: locked ? (_) {} : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
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
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  22,
                  20,
                  22,
                  footer == null ? 20 + bottom : 12,
                ),
                child: child,
              ),
            ),
            if (footer != null)
              Padding(
                padding: EdgeInsets.fromLTRB(22, 16, 22, 16 + bottom),
                child: footer,
              ),
          ],
        ),
      ),
    );
  }
}

class MiniSheetHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Color? tint;

  const MiniSheetHeader({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MiniIconPlate(
          icon: icon,
          tint: tint ?? c.accent,
          size: 48,
          iconSize: 22,
          radius: 12,
        ),
        const SizedBox(height: 16),
        Semantics(
          header: true,
          child: Text(
            title,
            style: MiniText.title.copyWith(color: c.ink, fontSize: 21),
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 8),
          Text(
            message!,
            style: MiniText.bodySoft.copyWith(color: c.inkSoft, height: 1.5),
          ),
        ],
      ],
    );
  }
}

/// Informational sheet: header, content blocks, and a Done button — plus an
/// optional primary action that closes the sheet before it runs.
Future<void> showMiniInfoSheet(
  BuildContext context, {
  required IconData icon,
  required String title,
  String? message,
  Color? tint,
  List<Widget> children = const [],
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final hasAction = actionLabel != null && onAction != null;
  return showMiniSheet<void>(
    context,
    builder: (sheetContext) => MiniSheetFrame(
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasAction) ...[
            MiniButton(
              label: actionLabel,
              onPressed: () {
                Navigator.pop(sheetContext);
                onAction();
              },
            ),
            const SizedBox(height: 10),
          ],
          MiniButton(
            label: 'Done',
            style: hasAction ? MiniBtnStyle.ghost : MiniBtnStyle.secondary,
            onPressed: () => Navigator.pop(sheetContext),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MiniSheetHeader(
            icon: icon,
            title: title,
            message: message,
            tint: tint,
          ),
          for (final child in children) ...[
            const SizedBox(height: 18),
            child,
          ],
        ],
      ),
    ),
  );
}

/// Body copy inside a sheet.
class MiniSheetText extends StatelessWidget {
  final String text;
  const MiniSheetText(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: MiniText.bodySoft.copyWith(
          color: context.mini.inkSoft,
          height: 1.5,
        ),
      );
}

/// A titled point inside a sheet: icon, short heading, one-line explanation.
class MiniSheetFact extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color? tint;

  const MiniSheetFact({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: tint ?? c.inkSoft),
          ),
          const SizedBox(width: 12),
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
                const SizedBox(height: 3),
                Text(
                  body,
                  style: GoogleFonts.outfit(
                    fontSize: 13.5,
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

/// Label/value pairs on a recessed well — account details and the like.
class MiniSheetDetails extends StatelessWidget {
  final List<(String, String)> rows;
  const MiniSheetDetails({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: miniWell(context),
      child: Column(
        children: [
          for (final (label, value) in rows)
            MergeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: MiniText.small.copyWith(
                          color: c.inkSoft,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        value,
                        textAlign: TextAlign.end,
                        style: GoogleFonts.outfit(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          height: 1.35,
                          color: c.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Numbered walkthrough steps.
class MiniSheetSteps extends StatelessWidget {
  final List<(String, String)> steps;
  const MiniSheetSteps({super.key, required this.steps});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 16),
            child: MergeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.accentSoft,
                      borderRadius: BorderRadius.circular(MiniRadius.chip),
                    ),
                    child: Text(
                      '${i + 1}',
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
                        const SizedBox(height: 4),
                        Text(
                          steps[i].$1,
                          style: GoogleFonts.outfit(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.2,
                            color: c.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          steps[i].$2,
                          style: GoogleFonts.outfit(
                            fontSize: 13.5,
                            height: 1.45,
                            color: c.inkSoft,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Tinted notice for a caution or an error inside a sheet.
class MiniInlineNotice extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color tint;

  const MiniInlineNotice({
    super.key,
    required this.icon,
    required this.text,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 12, 14, 12),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: context.isDarkMini ? 0.16 : 0.10),
          borderRadius: BorderRadius.circular(MiniRadius.control),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 17, color: tint),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.outfit(
                  fontSize: 13.5,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                  color: tint,
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
// Destructive confirmation
// ---------------------------------------------------------------------------

/// How a destructive action treats one group of data.
enum MiniImpact { removed, changed, kept }

/// One block of a confirmation sheet's "what happens" summary — e.g. what is
/// removed on this device, what changes on the server, what is left alone.
class MiniImpactGroup {
  final String title;
  final MiniImpact kind;
  final List<String> items;

  const MiniImpactGroup(this.title, this.kind, this.items);
}

/// A failure whose message is written for people; the confirmation sheet
/// shows it as-is. Anything else becomes a generic try-again message.
class MiniActionError implements Exception {
  final String message;
  const MiniActionError(this.message);

  @override
  String toString() => message;
}

/// Asks before a destructive action and runs it in place: spells out what
/// changes on this device and on MiniGo's servers, shows progress on the
/// destructive button, and keeps the sheet open with the error if [onConfirm]
/// throws. Resolves true once the action has completed.
///
/// With [requiresConnection] the button stays disabled while the device is
/// offline, for actions the server has to carry out.
Future<bool> showMiniConfirmSheet(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String message,
  required String confirmLabel,
  required Future<void> Function() onConfirm,
  List<MiniImpactGroup> impact = const [],
  String? warning,
  String? footnote,
  bool requiresConnection = false,
}) async {
  final done = await showMiniSheet<bool>(
    context,
    builder: (_) => _ConfirmSheet(
      icon: icon,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      onConfirm: onConfirm,
      impact: impact,
      warning: warning,
      footnote: footnote,
      requiresConnection: requiresConnection,
    ),
  );
  return done ?? false;
}

class _ConfirmSheet extends StatefulWidget {
  final IconData icon;
  final String title;
  final String message;
  final String confirmLabel;
  final Future<void> Function() onConfirm;
  final List<MiniImpactGroup> impact;
  final String? warning;
  final String? footnote;
  final bool requiresConnection;

  const _ConfirmSheet({
    required this.icon,
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.onConfirm,
    required this.impact,
    required this.warning,
    required this.footnote,
    required this.requiresConnection,
  });

  @override
  State<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends State<_ConfirmSheet> {
  bool _running = false;
  String? _error;

  Future<void> _confirm() async {
    HapticFeedback.mediumImpact();
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      await widget.onConfirm();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = e is MiniActionError
            ? e.message
            : 'Something went wrong, so nothing was changed. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final explanation = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MiniSheetHeader(
          icon: widget.icon,
          title: widget.title,
          message: widget.message,
          tint: MiniColors.danger,
        ),
        for (var i = 0; i < widget.impact.length; i++) ...[
          SizedBox(height: i == 0 ? 20 : 10),
          _ImpactCard(group: widget.impact[i]),
        ],
        if (widget.footnote != null) ...[
          const SizedBox(height: 10),
          Text(
            widget.footnote!,
            style: MiniText.small.copyWith(color: c.inkSoft, height: 1.45),
          ),
        ],
        if (widget.warning != null) ...[
          const SizedBox(height: 14),
          MiniInlineNotice(
            icon: MiniIcons.warning,
            text: widget.warning!,
            tint: MiniColors.warn,
          ),
        ],
      ],
    );

    return PopScope(
      canPop: !_running,
      child: ValueListenableBuilder<bool>(
        valueListenable: ConnectionStatus.instance.online,
        builder: (context, online, _) {
          final offline = widget.requiresConnection && !online;
          return MiniSheetFrame(
            locked: _running,
            // Notices sit with the buttons so an error is never scrolled
            // out of view from the action that caused it.
            footer: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (offline) ...[
                        const MiniInlineNotice(
                          icon: MiniIcons.offline,
                          text: 'You’re offline. Connect to the internet to '
                              'continue.',
                          tint: MiniColors.warn,
                        ),
                        const SizedBox(height: 14),
                      ],
                      if (_error != null) ...[
                        MiniInlineNotice(
                          icon: MiniIcons.error,
                          text: _error!,
                          tint: MiniColors.danger,
                        ),
                        const SizedBox(height: 14),
                      ],
                    ],
                  ),
                ),
                _DestructiveButton(
                  label: widget.confirmLabel,
                  loading: _running,
                  onPressed: offline ? null : _confirm,
                ),
                const SizedBox(height: 10),
                MiniButton(
                  label: 'Cancel',
                  style: MiniBtnStyle.secondary,
                  onPressed:
                      _running ? null : () => Navigator.pop(context, false),
                ),
              ],
            ),
            child: explanation,
          );
        },
      ),
    );
  }
}

class _ImpactCard extends StatelessWidget {
  final MiniImpactGroup group;
  const _ImpactCard({required this.group});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final (icon, tint) = switch (group.kind) {
      MiniImpact.removed => (MiniIcons.removed, MiniColors.danger),
      MiniImpact.changed => (MiniIcons.changed, MiniColors.warn),
      MiniImpact.kept => (MiniIcons.success, MiniColors.success),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: miniWell(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              group.title.toUpperCase(),
              style: MiniText.label.copyWith(
                color: c.inkSoft,
                letterSpacing: 0.9,
              ),
            ),
          ),
          for (final item in group.items) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1.5),
                  child: Icon(icon, size: 16, color: tint),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item,
                    style: GoogleFonts.outfit(
                      fontSize: 14,
                      height: 1.4,
                      color: c.ink,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Solid red pill — reserved for the final step of a destructive action.
class _DestructiveButton extends StatelessWidget {
  final String label;
  final bool loading;
  final VoidCallback? onPressed;

  const _DestructiveButton({
    required this.label,
    required this.loading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null && !loading;
    return Semantics(
      button: true,
      enabled: !disabled && !loading,
      label: loading ? '$label, in progress' : label,
      excludeSemantics: true,
      child: Opacity(
        opacity: disabled ? 0.45 : 1,
        child: Material(
          color: MiniColors.danger,
          borderRadius: BorderRadius.circular(MiniRadius.pill),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: loading ? null : onPressed,
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.black.withValues(alpha: 0.10),
            child: SizedBox(
              height: 54,
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: loading
                      ? const SizedBox.square(
                          key: ValueKey('loading'),
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            strokeCap: StrokeCap.round,
                            color: Colors.white,
                          ),
                        )
                      : Padding(
                          key: const ValueKey('label'),
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            label,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.1,
                              color: Colors.white,
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
