import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../Minigo/theme/mini_theme.dart';
import '../network/connection_status.dart';
import '../offline/offline_sync_coordinator.dart';
import '../offline/pending_backend_jobs.dart';

/// Global status banner that surfaces:
///   * Offline state (with retry queue summary, if any).
///   * "Syncing N items" while online with pending queued work.
/// Renders as a slim slot at the top of the shell — never blocks content.
class GlobalStatusBanner extends StatefulWidget {
  const GlobalStatusBanner({super.key});

  @override
  State<GlobalStatusBanner> createState() => _GlobalStatusBannerState();
}

class _GlobalStatusBannerState extends State<GlobalStatusBanner> {
  bool _retrying = false;

  Future<void> _retryNow() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await ConnectionStatus.instance.refresh();
      await OfflineSyncCoordinator.instance.runPendingWork();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  void initState() {
    super.initState();
    // Refresh once on mount so the banner reflects truth right after startup.
    PendingBackendJobs.refreshPendingCount();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectionStatus.instance.online,
      builder: (context, online, _) {
        return ValueListenableBuilder<int>(
          valueListenable: PendingBackendJobs.pendingCount,
          builder: (context, pending, __) {
            final hasPending = pending > 0;
            final show = !online || hasPending;
            return AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: show
                    ? _buildBanner(context, online, pending)
                    : const SizedBox(key: ValueKey('empty'), height: 0),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBanner(BuildContext context, bool online, int pending) {
    final isOffline = !online;
    final color = isOffline ? MiniColors.warn : MiniColors.blue600;
    final icon = isOffline
        ? Icons.cloud_off_rounded
        : Icons.sync_rounded;
    final text = isOffline
        ? (pending > 0
            ? 'Offline — $pending pending, will retry when back'
            : 'You are offline')
        : 'Syncing $pending pending…';

    return Material(
      key: const ValueKey('banner'),
      color: color.withOpacity(0.10),
      child: InkWell(
        onTap: online && pending > 0 ? _retryNow : null,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            child: Row(
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      color: color,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (online && pending > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _retrying
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: color,
                            ),
                          )
                        : Text(
                            'Retry now',
                            style: GoogleFonts.outfit(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: color,
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
