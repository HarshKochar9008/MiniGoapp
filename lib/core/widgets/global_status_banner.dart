import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../Minigo/theme/mini_theme.dart';
import '../errors/service_health.dart';
import '../network/connection_status.dart';
import '../offline/offline_sync_coordinator.dart';
import '../offline/pending_backend_jobs.dart';

/// Global status banner that surfaces:
///   * Offline state (with retry queue summary, if any).
///   * Backend outage ("service issues") when online but Supabase is down.
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

  Future<void> _checkServiceAgain() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await ServiceHealth.instance.check(force: true);
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
        return ValueListenableBuilder<BackendHealth>(
          valueListenable: ServiceHealth.instance.status,
          builder: (context, health, __) {
            return ValueListenableBuilder<int>(
              valueListenable: PendingBackendJobs.pendingCount,
              builder: (context, pending, ___) {
                final serviceDown =
                    online && health == BackendHealth.serviceDown;
                final hasPending = pending > 0;
                final show = !online || serviceDown || hasPending;
                return AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: show
                        ? _buildBanner(context, online, serviceDown, pending)
                        : const SizedBox(key: ValueKey('empty'), height: 0),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildBanner(
    BuildContext context,
    bool online,
    bool serviceDown,
    int pending,
  ) {
    final isOffline = !online;

    final Color color;
    final IconData icon;
    final String text;
    final String? actionLabel;
    final VoidCallback? onTap;

    if (isOffline) {
      color = MiniColors.warn;
      icon = Icons.cloud_off_rounded;
      text = pending > 0
          ? 'Offline — $pending pending, will retry when back'
          : 'You are offline';
      actionLabel = null;
      onTap = null;
    } else if (serviceDown) {
      color = MiniColors.danger;
      icon = Icons.report_gmailerrorred_rounded;
      text = 'Service issues — some features may not work right now';
      actionLabel = 'Check again';
      onTap = _checkServiceAgain;
    } else {
      color = MiniColors.blue600;
      icon = Icons.sync_rounded;
      text = 'Syncing $pending pending…';
      actionLabel = 'Retry now';
      onTap = pending > 0 ? _retryNow : null;
    }

    return Material(
      key: const ValueKey('banner'),
      color: color.withValues(alpha: 0.10),
      child: InkWell(
        onTap: onTap,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    text,
                    style: GoogleFonts.outfit(
                      fontSize: 12.5,
                      color: color,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (actionLabel != null && onTap != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _retrying
                        ? SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              strokeCap: StrokeCap.round,
                              color: color,
                            ),
                          )
                        : Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.16),
                              borderRadius:
                                  BorderRadius.circular(MiniRadius.pill),
                            ),
                            child: Text(
                              actionLabel,
                              style: GoogleFonts.outfit(
                                fontSize: 11.5,
                                height: 1.2,
                                fontWeight: FontWeight.w600,
                                color: color,
                              ),
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
