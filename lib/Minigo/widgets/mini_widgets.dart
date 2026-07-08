import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mime/mime.dart';
import '../theme/mini_theme.dart';

/// Code chip — formatted "A4X · 9K2" with subtle border.
class CodeChip extends StatelessWidget {
  final String code;
  final double fontSize;
  final EdgeInsets padding;
  final Color? color;
  const CodeChip({
    super.key,
    required this.code,
    this.fontSize = 14,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: c.paper,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.divider),
      ),
      child: Text(
        fmtCode(code),
        style: GoogleFonts.jetBrainsMono(
          fontSize: fontSize,
          color: color ?? c.ink,
          letterSpacing: fontSize > 18 ? 2 : 1,
        ),
      ),
    );
  }
}

/// Reusable button — primary (ink) / secondary (paper) / ghost / danger.
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
    switch (style) {
      case MiniBtnStyle.primary:
        bg = c.ink;
        fg = c.paper;
      case MiniBtnStyle.secondary:
        bg = c.paper;
        fg = c.ink;
        border = c.divider;
      case MiniBtnStyle.ghost:
        bg = Colors.transparent;
        fg = c.inkSoft;
      case MiniBtnStyle.danger:
        bg = c.paper;
        fg = MiniColors.danger;
        border = const Color(0x33B44A4A);
    }
    return Opacity(
      opacity: disabled ? 0.6 : 1,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: loading ? null : onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: fullWidth ? double.infinity : null,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading) ...[
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: fg.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(width: 10),
                ] else if (leading != null) ...[
                  leading!,
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: disabled ? fg.withValues(alpha: 0.4) : fg,
                    letterSpacing: 0.2,
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
    if (mime.contains('document') || mime.contains('word') || mime.contains('text/')) {
      return 'Document';
    }
    return 'File';
  }

  IconData get _icon {
    switch (mimeCategory) {
      case 'Image':
        return Icons.image_outlined;
      case 'Video':
        return Icons.play_circle_outline;
      case 'Audio':
        return Icons.graphic_eq;
      case 'PDF':
      case 'Document':
        return Icons.description_outlined;
      case 'Archive':
        return Icons.folder_zip_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  List<Color> _tone(BuildContext context) {
    final c = context.mini;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Light mode: original pastels. Dark mode: same hue as a subtle tint
    // blended over the dark surface so the tile doesn't glow.
    List<Color> pair(Color a, Color b) => dark
        ? [
            Color.alphaBlend(a.withValues(alpha: 0.16), c.paperDeep),
            c.paperDeep,
          ]
        : [a, b];
    switch (mimeCategory) {
      case 'Image':
        return pair(MiniColors.blue200, MiniColors.blue50);
      case 'Video':
        return pair(const Color(0xFFF2DFDF), c.paperDeep);
      case 'Audio':
        return pair(const Color(0xFFE0EFE6), c.paperDeep);
      case 'PDF':
      case 'Document':
        return pair(const Color(0xFFE6DFF2), c.paperDeep);
      case 'Archive':
        return pair(const Color(0xFFDCE8F6), c.paperDeep);
      default:
        return [c.sand, c.paperDeep];
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: LinearGradient(
                colors: _tone(context),
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Icon(_icon, color: c.ink.withValues(alpha: 0.55), size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    color: c.ink,
                    fontWeight: FontWeight.w500,
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

/// Circular progress arc — quiet ring with serif percentage.
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
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 5,
              strokeCap: StrokeCap.round,
              backgroundColor: c.paperDeep,
              valueColor: AlwaysStoppedAnimation(color ?? c.accent),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$pct%',
                style: GoogleFonts.outfit(
                  fontSize: size * 0.28,
                  height: 1,
                  color: c.ink,
                  letterSpacing: -1,
                ),
              ),
              if (label != null) ...[
                const SizedBox(height: 4),
                Text(label!, style: MiniText.small.copyWith(color: c.inkSoft)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Section header with serif title + optional small counter.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? counter;
  const SectionHeader({super.key, required this.title, this.counter});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(title,
              style: GoogleFonts.outfit(
                fontSize: 18,
                color: c.ink,
              )),
          if (counter != null) ...[
            const SizedBox(width: 8),
            Text(counter!, style: MiniText.label.copyWith(color: c.inkSoft)),
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
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.08),
          border: Border.all(color: tint.withValues(alpha: 0.18)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: tint),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  height: 1.4,
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
          borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(-1 + 2 * t, 0),
                  end: Alignment(0 + 2 * t, 0),
                  colors: [
                    c.paperDeep,
                    c.sand.withValues(alpha: 0.55),
                    c.paperDeep,
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
            borderRadius: BorderRadius.circular(10),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                MiniSkeleton(width: 140, height: 12),
                SizedBox(height: 8),
                MiniSkeleton(width: 80, height: 10),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const MiniSkeleton(width: 38, height: 10),
        ],
      ),
    );
  }
}

/// Pill-style tab selector.
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
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? c.paper : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: active
              ? const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  )
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.outfit(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: active ? c.ink : c.inkSoft,
          ),
        ),
      ),
    );
  }
}
