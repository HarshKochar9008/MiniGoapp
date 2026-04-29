import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../zensend/theme/zen_theme.dart';
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
              Text(header, style: ZenText.small),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: states.isNotEmpty ? completed / states.length : 0,
                  minHeight: 3,
                  backgroundColor: ZenColors.divider,
                  valueColor: const AlwaysStoppedAnimation(ZenColors.blue500),
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
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZenColors.paperDeep,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZenColors.dividerSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _statusIcon(),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  state.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                      fontSize: 13, color: ZenColors.ink),
                ),
              ),
              Text(
                _statusLabel(),
                style: GoogleFonts.inter(
                  color: _statusColor(),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          if (state.status == FileUploadStatus.hashing ||
              state.status == FileUploadStatus.uploading) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: state.progress,
                backgroundColor: ZenColors.divider,
                valueColor: AlwaysStoppedAnimation(_statusColor()),
                minHeight: 3,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              state.status == FileUploadStatus.hashing
                  ? 'Verifying… ${(state.progress * 100).toInt()}%'
                  : 'Uploading… ${(state.progress * 100).toInt()}%'
                      '${state.attempt > 1 ? ' (retry ${state.attempt})' : ''}',
              style: ZenText.small,
            ),
          ],
          if (state.status == FileUploadStatus.completed &&
              state.sha256 != null) ...[
            const SizedBox(height: 4),
            Text(
              'SHA-256: ${state.sha256!.substring(0, 16)}…',
              style: GoogleFonts.jetBrainsMono(
                color: ZenColors.inkFaint,
                fontSize: 10,
              ),
            ),
          ],
          if (state.status == FileUploadStatus.failed &&
              state.error != null) ...[
            const SizedBox(height: 4),
            Text(
              state.error!,
              style: GoogleFonts.inter(
                  color: ZenColors.danger, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusIcon() {
    switch (state.status) {
      case FileUploadStatus.pending:
        return const Icon(Icons.schedule_rounded,
            color: ZenColors.inkFaint, size: 18);
      case FileUploadStatus.hashing:
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: ZenColors.blue500,
          ),
        );
      case FileUploadStatus.uploading:
        return const Icon(Icons.cloud_upload_outlined,
            color: ZenColors.blue600, size: 18);
      case FileUploadStatus.completed:
        return const Icon(Icons.check_circle_rounded,
            color: ZenColors.success, size: 18);
      case FileUploadStatus.failed:
        return const Icon(Icons.error_rounded,
            color: ZenColors.danger, size: 18);
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

  Color _statusColor() {
    switch (state.status) {
      case FileUploadStatus.pending:
        return ZenColors.inkFaint;
      case FileUploadStatus.hashing:
        return ZenColors.blue500;
      case FileUploadStatus.uploading:
        return ZenColors.blue600;
      case FileUploadStatus.completed:
        return ZenColors.success;
      case FileUploadStatus.failed:
        return ZenColors.danger;
    }
  }
}
