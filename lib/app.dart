import 'dart:io';
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/constants.dart';
import 'core/navigation/root_navigator.dart';
import 'core/network/connection_status.dart';
import 'core/network/network_errors.dart';
import 'core/notifications/notification_service.dart';
import 'core/offline/offline_sync_coordinator.dart';
import 'core/supabase_config.dart';
import 'core/theme.dart';
import 'features/home/home_screen.dart';
import 'features/history/history_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/receive/received_tab_screen.dart';
import 'features/identity/identity_service.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'zensend/theme/zen_theme.dart';

class ZenSendApp extends StatelessWidget {
  const ZenSendApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.themeMode,
      builder: (context, themeMode, _) => MaterialApp(
        navigatorKey: rootNavigatorKey,
        title: 'ZenSend',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        darkTheme: buildDarkAppTheme(),
        themeMode: ThemeMode.light,
        home: const _AppEntry(),
      ),
    );
  }
}

class _AppEntry extends StatefulWidget {
  const _AppEntry();

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  bool? _onboardingComplete;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool('onboarding_complete') ?? false;
    if (mounted) setState(() => _onboardingComplete = done);
  }

  @override
  Widget build(BuildContext context) {
    if (_onboardingComplete == null) {
      return const Scaffold(
        backgroundColor: ZenColors.paper,
        body: SizedBox.shrink(),
      );
    }

    if (!_onboardingComplete!) {
      return OnboardingScreen(
        onComplete: () => setState(() => _onboardingComplete = true),
      );
    }

    return const MainShell();
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _currentIndex = 0;
  UserIdentity? _identity;
  bool _loading = true;
  String? _error;
  Timer? _networkRetryTimer;
  static const Duration _networkRetryDelay = Duration(seconds: 5);
  static const int _maxAutoRetryAttempts = 3;
  int _autoRetryAttempts = 0;
  bool _runningDiagnostics = false;
  String? _diagnosticsReport;
  VoidCallback? _connectivityListener;

  Future<UserIdentity> _initializeIdentityWithRetry() async {
    // Keep startup responsive: one bounded attempt here, then let the
    // outer auto-retry scheduler handle subsequent retries.
    return await IdentityService.initialize().timeout(
      const Duration(seconds: 15),
    );
  }

  bool _isNetworkLookupFailure(Object error) =>
      NetworkErrors.isRetryableFailure(error);

  String _buildStartupErrorMessage(Object error, {required bool willAutoRetry}) {
    if (_isNetworkLookupFailure(error)) {
      if (willAutoRetry) {
        return 'Could not reach Supabase. Check your internet connection. Retrying…';
      }
      return 'Could not reach Supabase. Check your internet connection, then tap Retry.';
    }
    return kDebugMode
        ? 'Startup failed: $error'
        : 'Could not connect. Check your internet and try again.';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ConnectionStatus.instance.ensureStarted();
    _connectivityListener = () {
      if (!ConnectionStatus.instance.online.value) return;
      if (_identity == null && _error != null && !_loading && mounted) {
        _loadIdentity();
      }
    };
    ConnectionStatus.instance.online.addListener(_connectivityListener!);
    NotificationService.handleLaunchAndPendingNavigation();
    _loadIdentity();
  }

  @override
  void dispose() {
    OfflineSyncCoordinator.instance.stop();
    if (_connectivityListener != null) {
      ConnectionStatus.instance.online.removeListener(_connectivityListener!);
    }
    _networkRetryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ConnectionStatus.instance.refresh());
      if (_identity == null && _error != null && !_loading) {
        _loadIdentity();
      } else if (_identity != null) {
        NotificationService.syncFcmToken(_identity!.id);
        unawaited(OfflineSyncCoordinator.instance.onAppResumed());
      }
    }
  }

  Future<void> _loadIdentity({bool fromAutoRetry = false}) async {
    _networkRetryTimer?.cancel();
    if (!fromAutoRetry) {
      _autoRetryAttempts = 0;
    }
    setState(() {
      _loading = true;
      _error = null;
      _diagnosticsReport = null;
    });
    try {
      final identity = await _initializeIdentityWithRetry();
      if (mounted) {
        NotificationService.setUserId(identity.id);
        await NotificationService.syncFcmToken(identity.id);
        NotificationService.handleLaunchAndPendingNavigation();
        OfflineSyncCoordinator.instance.start(userId: identity.id);
        unawaited(OfflineSyncCoordinator.instance.runPendingWork());
        setState(() {
          _identity = identity;
          _loading = false;
          _autoRetryAttempts = 0;
        });
      }
    } on AuthFailedException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } on StateError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        final networkFailure = _isNetworkLookupFailure(e);
        final willAutoRetry =
            networkFailure && _autoRetryAttempts < _maxAutoRetryAttempts;
        setState(() {
          _error = _buildStartupErrorMessage(e, willAutoRetry: willAutoRetry);
          _loading = false;
        });
        if (willAutoRetry) {
          _scheduleAutoRetry();
        }
      }
    }
  }

  void _scheduleAutoRetry() {
    _networkRetryTimer?.cancel();
    _networkRetryTimer = Timer(_networkRetryDelay, () {
      if (!mounted || _loading) return;
      _autoRetryAttempts++;
      _loadIdentity(fromAutoRetry: true);
    });
  }

  Future<void> _runDiagnostics() async {
    if (_runningDiagnostics) return;
    setState(() {
      _runningDiagnostics = true;
      _diagnosticsReport = 'Running diagnostics…';
    });

    final lines = <String>[];
    try {
      final connectivity = await Connectivity().checkConnectivity();
      lines.add('Connectivity: ${connectivity.map((e) => e.name).join(", ")}');
    } catch (e) {
      lines.add('Connectivity check failed: $e');
    }

    final host = Uri.parse(AppConstants.supabaseUrl).host;
    try {
      final lookup = await InternetAddress.lookup(host);
      lines.add(
        'DNS lookup: OK (${lookup.map((e) => e.address).toSet().join(", ")})',
      );
    } catch (e) {
      lines.add('DNS lookup: FAILED ($e)');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .getUrl(Uri.parse('${AppConstants.supabaseUrl}/auth/v1/health'));
      request.headers.add('apikey', AppConstants.supabaseAnonKey);
      final response = await request.close();
      lines.add('Auth health endpoint: HTTP ${response.statusCode}');
    } catch (e) {
      lines.add('Auth health endpoint: FAILED ($e)');
    } finally {
      client.close(force: true);
    }

    try {
      await SupabaseConfig.ensureValidSession();
      lines.add('Session refresh check: OK');
    } catch (e) {
      lines.add('Session refresh check: FAILED ($e)');
    }

    if (mounted) {
      setState(() {
        _runningDiagnostics = false;
        _diagnosticsReport = lines.join('\n');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: ZenColors.paper,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: ZenColors.blue600,
                ),
              ),
              const SizedBox(height: 28),
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: ZenColors.blue600,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Setting up…',
                style: GoogleFonts.inter(
                  color: ZenColors.inkSoft,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: ZenColors.paper,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off_rounded,
                    size: 48, color: ZenColors.inkFaint),
                const SizedBox(height: 24),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    color: ZenColors.inkSoft,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 32),
                _ZenActionButton(
                  label: 'Retry',
                  onPressed: _loadIdentity,
                ),
                const SizedBox(height: 10),
                _ZenGhostButton(
                  label: _runningDiagnostics
                      ? 'Running diagnostics…'
                      : 'Run diagnostics',
                  onPressed: _runningDiagnostics ? null : _runDiagnostics,
                ),
                if (_diagnosticsReport != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: ZenColors.paperDeep,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: ZenColors.divider),
                    ),
                    child: Text(
                      _diagnosticsReport!,
                      style: GoogleFonts.jetBrainsMono(
                        color: ZenColors.inkSoft,
                        fontSize: 11,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    final tabs = [
      HomeScreen(identity: _identity!),
      ReceivedTabScreen(identity: _identity!),
      HistoryScreen(identity: _identity!),
      SettingsScreen(identity: _identity!),
    ];

    return Scaffold(
      backgroundColor: ZenColors.paper,
      body: IndexedStack(
        index: _currentIndex,
        children: tabs,
      ),
      bottomNavigationBar: _ZenBottomNav(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
      ),
    );
  }
}

class _ZenBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _ZenBottomNav({required this.currentIndex, required this.onTap});

  static const _items = [
    _NavItem(icon: Icons.home_outlined, activeIcon: Icons.home_rounded, label: 'Home'),
    _NavItem(icon: Icons.south_west_outlined, activeIcon: Icons.south_west, label: 'Received'),
    _NavItem(icon: Icons.access_time_outlined, activeIcon: Icons.access_time_rounded, label: 'History'),
    _NavItem(icon: Icons.settings_outlined, activeIcon: Icons.settings_rounded, label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: ZenColors.paper,
        border: Border(
          top: BorderSide(color: ZenColors.dividerSoft),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(_items.length, (i) {
              final item = _items[i];
              final isActive = i == currentIndex;
              return _ZenNavTile(
                icon: item.icon,
                activeIcon: item.activeIcon,
                label: item.label,
                isActive: isActive,
                onTap: () => onTap(i),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _NavItem({required this.icon, required this.activeIcon, required this.label});
}

class _ZenNavTile extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _ZenNavTile({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isActive ? activeIcon : icon,
              size: 22,
              color: isActive ? ZenColors.blue600 : ZenColors.inkFaint,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                color: isActive ? ZenColors.blue600 : ZenColors.inkFaint,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZenActionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const _ZenActionButton({required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: ZenColors.ink,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: ZenColors.paper,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ZenGhostButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const _ZenGhostButton({required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: ZenColors.inkSoft,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
