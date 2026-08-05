import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../Minigo/theme/mini_theme.dart';
import 'transfer_service.dart';

class TransferUploadProgressList extends StatelessWidget {
  final List<FileUploadProgress> states;
  final String? headerPrefix;

  const TransferUploadProgressList({
    super.key,
    required this.states,
    this.headerPrefix,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final completed =
        states.where((s) => s.status == FileUploadStatus.completed).length;
    final tail = '$completed / ${states.length} uploaded';
    final header = headerPrefix != null ? '$headerPrefix · $tail' : tail;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                header,
                style: MiniText.small.copyWith(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(MiniRadius.pill),
                child: LinearProgressIndicator(
                  value: states.isNotEmpty ? completed / states.length : 0,
                  minHeight: 7,
                  backgroundColor: c.sand,
                  valueColor: AlwaysStoppedAnimation(c.accent),
                ),
              ),
            ],
          ),
        ),
        ...states.map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TransferFileProgressTile(state: s),
            )),
      ],
    );
  }
}

class TransferFileProgressTile extends StatelessWidget {
  final FileUploadProgress state;
  const TransferFileProgressTile({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: miniCard(context, radius: MiniRadius.tile),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _statusIcon(c),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  state.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.outfit(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.2,
                    color: c.ink,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _statusLabel(),
                style: GoogleFonts.outfit(
                  color: _statusColor(c),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          if (state.status == FileUploadStatus.hashing ||
              state.status == FileUploadStatus.uploading) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(MiniRadius.pill),
              child: LinearProgressIndicator(
                value: state.progress,
                backgroundColor: c.sand,
                valueColor: AlwaysStoppedAnimation(_statusColor(c)),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              state.status == FileUploadStatus.hashing
                  ? 'Verifying… ${(state.progress * 100).toInt()}%'
                  : 'Uploading… ${(state.progress * 100).toInt()}%'
                      '${state.attempt > 1 ? ' (retry ${state.attempt})' : ''}',
              style: MiniText.small,
            ),
          ],
          if (state.status == FileUploadStatus.completed &&
              state.sha256 != null) ...[
            const SizedBox(height: 6),
            Text(
              'SHA-256: ${state.sha256!.substring(0, 16)}…',
              style: GoogleFonts.jetBrainsMono(
                color: c.inkFaint,
                fontSize: 11,
              ),
            ),
          ],
          if (state.status == FileUploadStatus.failed &&
              state.error != null) ...[
            const SizedBox(height: 6),
            Text(
              state.error!,
              style: GoogleFonts.outfit(
                color: MiniColors.danger,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusIcon(MiniThemeExtension c) {
    switch (state.status) {
      case FileUploadStatus.pending:
        return Icon(Icons.schedule_rounded, color: c.inkFaint, size: 18);
      case FileUploadStatus.hashing:
        return SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: c.accent,
          ),
        );
      case FileUploadStatus.uploading:
        return Icon(Icons.cloud_upload_outlined, color: c.accent, size: 18);
      case FileUploadStatus.completed:
        return const Icon(Icons.check_circle_rounded,
            color: MiniColors.success, size: 18);
      case FileUploadStatus.failed:
        return const Icon(Icons.error_rounded,
            color: MiniColors.danger, size: 18);
    }
  }

  String _statusLabel() {
    switch (state.status) {
      case FileUploadStatus.pending:
        return 'Queued';
      case FileUploadStatus.hashing:
        return 'Hashing';
      case FileUploadStatus.uploading:
        return 'Uploading';
      case FileUploadStatus.completed:
        return 'Sent';
      case FileUploadStatus.failed:
        return 'Failed';
    }
  }

  Color _statusColor(MiniThemeExtension c) {
    switch (state.status) {
      case FileUploadStatus.pending:
        return c.inkFaint;
      case FileUploadStatus.hashing:
        return c.accent;
      case FileUploadStatus.uploading:
        return c.accent;
      case FileUploadStatus.completed:
        return MiniColors.success;
      case FileUploadStatus.failed:
        return MiniColors.danger;
    }
  }
}
