import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mime/mime.dart';
import '../theme/mini_theme.dart';

/// Raised panel — the primary grouping surface. Content sits on white (light)
/// or lifted charcoal (dark) above the recessed page background.
class MiniCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets? margin;
  final double radius;
  final Color? color;
  final bool strong;
  final VoidCallback? onTap;

  const MiniCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.margin,
    this.radius = MiniRadius.card,
    this.color,
    this.strong = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final body = Container(
      margin: margin,
      decoration: miniCard(
        context,
        radius: radius,
        color: color,
        strong: strong,
      ),
      child: onTap == null
          ? Padding(padding: padding, child: child)
          : Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(radius),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(radius),
                child: Padding(padding: padding, child: child),
              ),
            ),
    );
    return body;
  }
}

/// Rounded tinted plate behind an icon — the app's main iconography frame.
class MiniIconPlate extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final double size;
  final double iconSize;
  final double radius;

  const MiniIconPlate({
    super.key,
    required this.icon,
    required this.tint,
    this.size = 44,
    this.iconSize = 21,
    this.radius = 9,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: context.isDarkMini ? 0.20 : 0.13),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(icon, color: tint, size: iconSize),
    );
  }
}

/// Code chip — formatted "A4X · 9K2" on a recessed fill.
class CodeChip extends StatelessWidget {
  final String code;
  final double fontSize;
  final EdgeInsets padding;
  final Color? color;
  const CodeChip({
    super.key,
    required this.code,
    this.fontSize = 14,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: c.sand,
        borderRadius: BorderRadius.circular(MiniRadius.pill),
      ),
      child: Text(
        fmtCode(code),
        style: GoogleFonts.jetBrainsMono(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: color ?? c.ink,
          letterSpacing: fontSize > 18 ? 2 : 0.8,
        ),
      ),
    );
  }
}

/// Reusable button — primary (ink) / secondary (raised) / ghost / danger.
enum MiniBtnStyle { primary, secondary, ghost, danger }

class MiniButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final MiniBtnStyle style;
  final Widget? leading;
  final bool fullWidth;
  final bool loading;
  const MiniButton({
    super.key,
    required this.label,
    this.onPressed,
    this.style = MiniBtnStyle.primary,
    this.leading,
    this.fullWidth = true,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final disabled = onPressed == null && !loading;
    Color bg, fg;
    Color border = Colors.transparent;
    List<BoxShadow> shadow = const [];
    switch (style) {
      case MiniBtnStyle.primary:
        bg = c.ink;
        fg = context.isDarkMini ? c.paper : Colors.white;
        shadow = miniCardShadow(context);
      case MiniBtnStyle.secondary:
        bg = c.paperDeep;
        fg = c.ink;
        border = c.divider;
        shadow = miniCardShadow(context);
      case MiniBtnStyle.ghost:
        bg = Colors.transparent;
        fg = c.inkSoft;
      case MiniBtnStyle.danger:
        bg = MiniColors.danger.withValues(alpha: 0.12);
        fg = MiniColors.danger;
    }
    return Opacity(
      opacity: disabled ? 0.45 : 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(MiniRadius.pill),
          boxShadow: disabled ? const [] : shadow,
        ),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(MiniRadius.pill),
          child: InkWell(
            onTap: loading ? null : onPressed,
            borderRadius: BorderRadius.circular(MiniRadius.pill),
            child: Container(
              width: fullWidth ? double.infinity : null,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 17),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(MiniRadius.pill),
                border: Border.all(color: border),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading) ...[
                    SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        strokeCap: StrokeCap.round,
                        color: fg.withValues(alpha: 0.8),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ] else if (leading != null) ...[
                    leading!,
                    const SizedBox(width: 9),
                  ],
                  Text(
                    label,
                    style: GoogleFonts.outfit(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: fg,
                      letterSpacing: -0.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// File row for the send flow — accepts raw strings, no MiniFile model.
class MiniFileRow extends StatelessWidget {
  final String name;
  final String size;
  final String mimeCategory;
  final Widget? trailing;
  final EdgeInsets padding;
  const MiniFileRow({
    super.key,
    required this.name,
    required this.size,
    this.mimeCategory = 'File',
    this.trailing,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  static String categoryFromFileName(String fileName) {
    final mime = lookupMimeType(fileName) ?? '';
    if (mime.startsWith('image/')) return 'Image';
    if (mime.startsWith('video/')) return 'Video';
    if (mime.startsWith('audio/')) return 'Audio';
    if (mime.contains('pdf')) return 'PDF';
    if (mime.contains('zip') || mime.contains('tar') || mime.contains('rar')) {
      return 'Archive';
    }
    if (mime.contains('document') ||
        mime.contains('word') ||
        mime.contains('text/')) {
      return 'Document';
    }
    return 'File';
  }

  IconData get _icon {
    switch (mimeCategory) {
      case 'Image':
        return Icons.image_rounded;
      case 'Video':
        return Icons.play_circle_fill_rounded;
      case 'Audio':
        return Icons.graphic_eq_rounded;
      case 'PDF':
      case 'Document':
        return Icons.description_rounded;
      case 'Archive':
        return Icons.folder_zip_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  /// File kind is carried by the glyph alone — a colour per type would put five
  /// extra hues in every list for no information the icon doesn't already give.
  Color tintFor(BuildContext context) => context.mini.inkSoft;

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          MiniIconPlate(icon: _icon, tint: tintFor(context)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: GoogleFonts.outfit(
                    fontSize: 15,
                    color: c.ink,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.2,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(size, style: MiniText.small.copyWith(color: c.inkSoft)),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Thick single-colour ring with a large centered figure.
class ProgressArc extends StatelessWidget {
  final double progress;
  final double size;
  final String? label;
  final Color? color;
  const ProgressArc({
    super.key,
    required this.progress,
    this.size = 160,
    this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final pct = (progress * 100).round();
    final head = color ?? c.accent;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _GaugePainter(
              progress: progress.clamp(0.0, 1.0),
              track: c.sand,
              color: head,
              stroke: size * 0.075,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$pct%',
                style: GoogleFonts.outfit(
                  fontSize: size * 0.27,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  color: c.ink,
                  letterSpacing: -1.6,
                ),
              ),
              if (label != null) ...[
                const SizedBox(height: 5),
                Text(label!, style: MiniText.small.copyWith(color: c.inkSoft)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double progress;
  final Color track;
  final Color color;
  final double stroke;

  _GaugePainter({
    required this.progress,
    required this.track,
    required this.color,
    required this.stroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final inner = rect.deflate(stroke / 2);
    const start = -math.pi / 2;

    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(inner, start, math.pi * 2, false, trackPaint);

    if (progress <= 0) return;
    final valuePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(inner, start, math.pi * 2 * progress, false, valuePaint);
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.progress != progress ||
      old.track != track ||
      old.color != color ||
      old.stroke != stroke;
}

/// Section header with bold title + optional counter.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? counter;
  const SectionHeader({super.key, required this.title, this.counter});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
      child: Row(
        children: [
          Text(title, style: MiniText.heading.copyWith(color: c.ink)),
          if (counter != null) ...[
            const SizedBox(width: 9),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: c.sand,
                borderRadius: BorderRadius.circular(MiniRadius.pill),
              ),
              child: Text(
                counter!,
                style: GoogleFonts.outfit(
                  fontSize: 11,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  color: c.inkSoft,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Hairline divider.
class HairLine extends StatelessWidget {
  final double indent;
  const HairLine({super.key, this.indent = 0});
  @override
  Widget build(BuildContext context) => Container(
        height: 1,
        margin: EdgeInsets.only(left: indent),
        color: context.mini.dividerSoft,
      );
}

/// Status banner for warnings and offline states.
class StatusBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color tint;
  final VoidCallback? onTap;
  const StatusBanner({
    super.key,
    required this.icon,
    required this.text,
    required this.tint,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: tint.withValues(alpha: context.isDarkMini ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(MiniRadius.control),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MiniRadius.control),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Icon(icon, size: 19, color: tint),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    text,
                    style: GoogleFonts.outfit(
                      fontSize: 13.5,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                      color: tint,
                    ),
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

/// Shimmer-style skeleton block. Self-animates while in the tree.
class MiniSkeleton extends StatefulWidget {
  final double width;
  final double height;
  final BorderRadius? borderRadius;
  const MiniSkeleton({
    super.key,
    this.width = double.infinity,
    this.height = 14,
    this.borderRadius,
  });

  @override
  State<MiniSkeleton> createState() => _MiniSkeletonState();
}

class _MiniSkeletonState extends State<MiniSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        return ClipRRect(
          borderRadius: widget.borderRadius ?? BorderRadius.circular(5),
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(-1 + 2 * t, 0),
                  end: Alignment(0 + 2 * t, 0),
                  colors: [
                    c.sand,
                    c.sandDeep.withValues(alpha: 0.6),
                    c.sand,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Skeleton tile that mirrors the shape of a transfer list row.
class TransferTileSkeleton extends StatelessWidget {
  const TransferTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Row(
        children: [
          MiniSkeleton(
            width: 44,
            height: 44,
            borderRadius: BorderRadius.circular(9),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                MiniSkeleton(width: 150, height: 13),
                SizedBox(height: 9),
                MiniSkeleton(width: 84, height: 11),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const MiniSkeleton(width: 40, height: 11),
        ],
      ),
    );
  }
}

/// Segmented-control segment. Sits inside a `sand` track; the active segment
/// is a raised pill.
class MiniTabPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const MiniTabPill({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MiniRadius.pill),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: active ? c.paperDeep : Colors.transparent,
          borderRadius: BorderRadius.circular(MiniRadius.pill),
          boxShadow: active ? miniCardShadow(context) : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.outfit(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.1,
            color: active ? c.ink : c.inkSoft,
          ),
        ),
      ),
    );
  }
}
