import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/analytics/analytics.dart';
import 'core/constants.dart';
import 'core/contacts/contact_aliases.dart';
import 'core/errors/service_health.dart';
import 'core/native/share_intent_bridge.dart';
import 'core/navigation/root_navigator.dart';
import 'core/security/app_lock.dart';
import 'core/widget_bridge.dart';
import 'core/network/connection_status.dart';
import 'core/network/network_errors.dart';
import 'core/notifications/notification_service.dart';
import 'core/notifications/pending_push.dart';
import 'core/offline/offline_sync_coordinator.dart';
import 'core/offline/pending_backend_jobs.dart';
import 'core/security/security_gate.dart';
import 'core/supabase_config.dart';
import 'core/theme.dart';
import 'core/utils/local_platform_file.dart';
import 'core/widgets/global_status_banner.dart';
import 'Minigo/widgets/mini_ufo.dart';
import 'Minigo/widgets/mini_widgets.dart';
import 'features/home/home_screen.dart' show HomeScreen, HomeAutoAction;
import 'features/history/history_screen.dart';
import 'features/rooms/rooms_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/identity/identity_service.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding_v2/onboarding_experiment.dart';
import 'features/onboarding_v2/onboarding_flow.dart';
import 'features/send/send_screen.dart';
import 'Minigo/theme/mini_icons.dart';

class MiniGoApp extends StatelessWidget {
  const MiniGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.themeMode,
      builder: (context, themeMode, _) => MaterialApp(
        navigatorKey: rootNavigatorKey,
        title: 'MiniGo',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        darkTheme: buildDarkAppTheme(),
        themeMode: themeMode,
        builder: (context, child) {
          // MaterialApp has resolved light vs dark by here (including
          // ThemeMode.system). Sync the static MiniText palette so its
          // styles follow the theme without each call site needing context.
          MiniText.palette =
              Theme.of(context).extension<MiniThemeExtension>() ??
                  MiniThemeExtension.light;
          return SecurityGate(child: AppLockGate(child: child!));
        },
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
  OnboardingVariant _variant = OnboardingVariant.classic;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool('onboarding_complete') ?? false;
    // Only installs that still need onboarding join the A/B test.
    final variant =
        done ? OnboardingVariant.classic : await OnboardingExperiment.assign();
    if (mounted) {
      setState(() {
        _variant = variant;
        _onboardingComplete = done;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_onboardingComplete == null) {
      return Scaffold(
        backgroundColor: context.mini.paper,
        body: const SizedBox.shrink(),
      );
    }

    if (!_onboardingComplete!) {
      void done() {
        // main.dart only sets notifications up for installs that were
        // already onboarded. Listeners (foreground messages, taps, token
        // refresh) are needed in this session too; the permission prompt
        // stays with onboarding, so a "Skip for now" still holds.
        unawaited(NotificationService.initializeWithoutPrompt());
        setState(() => _onboardingComplete = true);
      }

      return _variant == OnboardingVariant.questionnaire
          ? OnboardingFlowV2(onComplete: done)
          : OnboardingScreen(onComplete: done);
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
  HomeAutoAction? _widgetAction;
  Timer? _networkRetryTimer;
  static const Duration _networkRetryDelay = Duration(seconds: 5);
  static const int _maxAutoRetryAttempts = 3;
  int _autoRetryAttempts = 0;
  VoidCallback? _connectivityListener;
  bool _consumingSharedFiles = false;

  /// The user id the per-user services (FCM token, offline drain) currently
  /// run for. Only ever a verified identity: a provisional one may belong to
  /// a retired row or a replaced session, and nothing may write to the
  /// server on its behalf.
  String? _servicesUserId;

  /// The user id analytics, the home-screen widget and notification-tap
  /// delivery were last set up for (provisional identities included).
  String? _localUserId;

  /// Re-verification of a provisional identity: on resume, when the network
  /// comes back, and on a backoff timer in between.
  Timer? _reverifyTimer;
  static const Duration _reverifyFirstDelay = Duration(seconds: 10);
  static const Duration _reverifyMaxDelay = Duration(minutes: 2);
  Duration _reverifyDelay = _reverifyFirstDelay;
  bool _reverifying = false;

  /// An app reset is replacing this shell: stop reacting to anything.
  bool _detached = false;

  /// If another app shared files to us (share sheet), open the Send flow
  /// with those files pre-selected.
  Future<void> _consumeSharedFiles() async {
    final identity = _identity;
    if (identity == null || _consumingSharedFiles) return;
    _consumingSharedFiles = true;
    try {
      final shared = await ShareIntentBridge.getAndClearSharedFiles();
      if (shared.isEmpty || !mounted) return;
      final files = shared
          .map((f) =>
              LocalPlatformFile(path: f.path, name: f.name, size: f.size))
          .toList();
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => SendScreen(identity: identity, initialFiles: files),
        ),
      );
    } finally {
      _consumingSharedFiles = false;
    }
  }

  /// If the app was opened via a minigo://send QR scanned with the system
  /// camera, open the Send flow with that recipient prefilled.
  Future<void> _consumeDeepLink() async {
    final identity = _identity;
    if (identity == null) return;
    final link = await ShareIntentBridge.getAndClearDeepLink();
    if (link == null || !mounted) return;
    final code = AppConstants.codeFromSendDeepLink(link);
    if (code == null) return;
    // Scanning your own QR shouldn't offer to send files to yourself.
    if (code == identity.shortCode) return;
    Analytics.instance
        .logEvent(AnalyticsEvents.qrScanned, {'source': 'system_camera'});
    rootNavigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) =>
            SendScreen(identity: identity, initialRecipientCode: code),
      ),
    );
  }

  Future<UserIdentity> _initializeIdentityWithRetry() async {
    // Keep startup responsive: one bounded attempt here, then let the
    // outer auto-retry scheduler handle subsequent retries.
    return await IdentityService.initialize().timeout(
      const Duration(seconds: 15),
    );
  }

  bool _isNetworkLookupFailure(Object error) =>
      NetworkErrors.isRetryableFailure(error);

  String _buildStartupErrorMessage(
    Object error, {
    required bool willAutoRetry,
    BackendHealth health = BackendHealth.unknown,
  }) {
    // Only claimed when the backend itself answered with a server error.
    if (health == BackendHealth.serviceDown) {
      return 'MiniGo is down right now. It’s not your connection. Try again '
          'in a few minutes.';
    }
    if (health == BackendHealth.offline) {
      return willAutoRetry
          ? 'No internet connection. Check your Wi‑Fi or mobile data. '
              'Retrying…'
          : 'No internet connection. Check your Wi‑Fi or mobile data, then '
              'tap Retry.';
    }
    if (_isNetworkLookupFailure(error)) {
      if (willAutoRetry) {
        return 'Can’t reach MiniGo. Check your connection. Retrying…';
      }
      return 'Can’t reach MiniGo. Check your connection, then tap Retry.';
    }
    if (kDebugMode) debugPrint('Startup failed: $error');
    return 'Can’t connect. Check your connection and try again.';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ConnectionStatus.instance.ensureStarted();
    _connectivityListener = () {
      if (_detached || !mounted) return;
      if (!ConnectionStatus.instance.online.value) return;
      if (_identity == null && _error != null && !_loading) {
        _loadIdentity();
      } else if (_identity != null) {
        unawaited(_reverifyIfProvisional());
      }
    };
    ConnectionStatus.instance.online.addListener(_connectivityListener!);
    IdentityService.identityNotifier.addListener(_onIdentityChanged);
    unawaited(ContactAliases.ensureLoaded());
    _loadIdentity();
  }

  /// Follows identity changes made elsewhere: a nickname edited in Settings,
  /// verification finishing, the identity being replaced by a new one, or
  /// dropped altogether.
  void _onIdentityChanged() {
    if (!mounted || _detached) return;
    final updated = IdentityService.identityNotifier.value;
    if (updated == null) {
      if (IdentityService.isResetting) {
        _detach();
        return;
      }
      // Dropped (its row turned out retired, or its session replaced): stop
      // acting for it and set up again, which picks up the replacement.
      if (_identity != null && !_loading) {
        _stopUserServices();
        _localUserId = null;
        PendingIncomingTransfer.disableDelivery(this);
        setState(() {
          _identity = null;
          _widgetAction = null;
        });
        _loadIdentity();
      }
      return;
    }
    // While nothing is shown yet, _loadIdentity applies its own result.
    if (_identity == null) return;
    _applyIdentity(updated);
  }

  /// Shows [identity] and brings the per-user side effects in line with it
  /// and with how far it's trusted.
  void _applyIdentity(UserIdentity identity) {
    final current = _identity;
    if (current == null ||
        current.id != identity.id ||
        current.nickname != identity.nickname ||
        current.shortCode != identity.shortCode) {
      setState(() => _identity = identity);
    }
    if (_servicesUserId != null && _servicesUserId != identity.id) {
      // A different user now: nothing may keep acting for the old one.
      _stopUserServices();
    }
    _setUpLocalFor(identity);
    if (IdentityService.isVerified &&
        IdentityService.identityNotifier.value?.id == identity.id) {
      _reverifyTimer?.cancel();
      _reverifyDelay = _reverifyFirstDelay;
      _startUserServices(identity);
    } else {
      _scheduleReverify();
    }
  }

  /// Device-local setup for whoever is shown: crash/analytics attribution,
  /// the home-screen widget, and opening tapped notifications.
  void _setUpLocalFor(UserIdentity identity) {
    if (_localUserId == identity.id) return;
    _localUserId = identity.id;
    Analytics.instance.identify(identity.id, shortCode: identity.shortCode);
    unawaited(WidgetBridge.refresh());
    PendingIncomingTransfer.enableDelivery(this);
    NotificationService.handleLaunchAndPendingNavigation();
  }

  /// Server-facing services for a verified identity. Idempotent per user.
  void _startUserServices(UserIdentity identity) {
    if (_servicesUserId == identity.id) return;
    _servicesUserId = identity.id;
    ServiceHealth.instance.markHealthy();
    NotificationService.setUserId(identity.id);
    // Not awaited: it queues itself for retry on failure, and the shell
    // shouldn't sit on a token fetch + DB round trip.
    unawaited(NotificationService.syncFcmToken(identity.id));
    // start() drains straight away when online.
    OfflineSyncCoordinator.instance.start(userId: identity.id);
    unawaited(PendingBackendJobs.refreshPendingCount());
    unawaited(IdentityService.flushPendingRetirements());
  }

  void _stopUserServices() {
    if (_servicesUserId == null) return;
    _servicesUserId = null;
    OfflineSyncCoordinator.instance.stop();
    NotificationService.setUserId(null);
  }

  void _detach() {
    _detached = true;
    _networkRetryTimer?.cancel();
    _reverifyTimer?.cancel();
    _stopUserServices();
    PendingIncomingTransfer.disableDelivery(this);
  }

  void _scheduleReverify() {
    if (_detached || (_reverifyTimer?.isActive ?? false)) return;
    final delay = _reverifyDelay;
    _reverifyTimer = Timer(delay, () => unawaited(_reverifyIfProvisional()));
    final doubled = delay * 2;
    _reverifyDelay = doubled > _reverifyMaxDelay ? _reverifyMaxDelay : doubled;
  }

  /// Checks a provisional identity against the server. The outcome also
  /// reaches [_onIdentityChanged], which is what applies it if this call's
  /// own timeout fires first.
  Future<void> _reverifyIfProvisional() async {
    if (_reverifying || _detached || !mounted) return;
    if (_identity == null || IdentityService.isVerified) return;
    _reverifyTimer?.cancel();
    _reverifying = true;
    try {
      final identity = await IdentityService.initialize()
          .timeout(const Duration(seconds: 20));
      if (!mounted || _detached || _identity == null) return;
      _applyIdentity(identity);
    } catch (_) {
      if (!mounted || _detached) return;
      // Dropped identities are handled by _onIdentityChanged.
      if (_identity != null && !IdentityService.isVerified) {
        _scheduleReverify();
      }
    } finally {
      _reverifying = false;
    }
  }

  @override
  void dispose() {
    _stopUserServices();
    PendingIncomingTransfer.disableDelivery(this);
    IdentityService.identityNotifier.removeListener(_onIdentityChanged);
    if (_connectivityListener != null) {
      ConnectionStatus.instance.online.removeListener(_connectivityListener!);
    }
    _networkRetryTimer?.cancel();
    _reverifyTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _detached) return;
    unawaited(ConnectionStatus.instance.refresh());
    final identity = _identity;
    if (identity == null) {
      if (_error != null && !_loading) _loadIdentity();
      return;
    }
    if (_servicesUserId == identity.id) {
      unawaited(NotificationService.syncFcmToken(identity.id));
      unawaited(OfflineSyncCoordinator.instance.onAppResumed());
      unawaited(IdentityService.flushPendingRetirements());
    } else {
      unawaited(_reverifyIfProvisional());
    }
    unawaited(_consumeSharedFiles());
    unawaited(_consumeDeepLink());
    WidgetBridge.getAndClearAction().then((rawAction) {
      if (!mounted || rawAction == null) return;
      HomeAutoAction? action;
      if (rawAction == 'send') action = HomeAutoAction.openSend;
      if (rawAction == 'qr') action = HomeAutoAction.showQr;
      if (action != null) {
        setState(() {
          _currentIndex = 0;
          _widgetAction = action;
        });
      }
    });
  }

  Future<void> _loadIdentity({bool fromAutoRetry = false}) async {
    if (_detached) return;
    _networkRetryTimer?.cancel();
    if (!fromAutoRetry) {
      _autoRetryAttempts = 0;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!SupabaseConfig.isInitialized) {
        // Startup init failed and was swallowed in main() — retry it here so
        // the Retry button can actually recover instead of failing forever.
        await initSupabase();
      }
      final identity = await _initializeIdentityWithRetry();
      if (!mounted || _detached) return;
      final rawAction = await WidgetBridge.getAndClearAction();
      if (!mounted || _detached) return;
      HomeAutoAction? widgetAction;
      if (rawAction == 'send') widgetAction = HomeAutoAction.openSend;
      if (rawAction == 'qr') widgetAction = HomeAutoAction.showQr;
      // The identity may have moved on while the widget was asked (e.g.
      // verified, or replaced): show the latest.
      final latest = IdentityService.identityNotifier.value ?? identity;
      setState(() {
        _identity = latest;
        _loading = false;
        _autoRetryAttempts = 0;
        _widgetAction = widgetAction;
        if (widgetAction != null) _currentIndex = 0;
      });
      _applyIdentity(latest);
      Analytics.instance.logEvent(AnalyticsEvents.identityReady);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_consumeSharedFiles());
        unawaited(_consumeDeepLink());
      });
    } on IdentityResetInProgressException {
      // The reset relaunches the app; this shell is on its way out.
      return;
    } on AuthFailedException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } on StateError catch (e) {
      // Configuration/init failures are developer problems — never show the
      // raw message to users; route it to Crashlytics and the console.
      Analytics.instance.logError('startup_config_error', e);
      if (kDebugMode) debugPrint('Startup config error: ${e.message}');
      if (mounted) {
        setState(() {
          _error = 'Close and reopen the app. If this keeps happening, '
              'contact support.';
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        final networkFailure = _isNetworkLookupFailure(e);
        final willAutoRetry =
            networkFailure && _autoRetryAttempts < _maxAutoRetryAttempts;
        // Distinguish "your connection is down" from "our service is down"
        // so the error screen tells the user the truth.
        final health = networkFailure || NetworkErrors.isServerFailure(e)
            ? await ServiceHealth.instance.check()
            : BackendHealth.unknown;
        if (!mounted || _detached) return;
        setState(() {
          _error = _buildStartupErrorMessage(
            e,
            willAutoRetry: willAutoRetry,
            health: health,
          );
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
      if (!mounted || _loading || _detached) return;
      _autoRetryAttempts++;
      _loadIdentity(fromAutoRetry: true);
    });
  }

  Future<void> _contactSupport() async {
    await Clipboard.setData(
      const ClipboardData(text: AppConstants.supportEmail),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Support email copied: ${AppConstants.supportEmail}'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final identity = _identity;
    if (_loading || (identity == null && _error == null)) {
      return Scaffold(
        backgroundColor: context.mini.paper,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MiniUfoLogo(size: 170),
              const SizedBox(height: 10),
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.6,
                  strokeCap: StrokeCap.round,
                  color: context.mini.accent,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Setting up…',
                style: GoogleFonts.outfit(
                  color: context.mini.inkSoft,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (identity == null) {
      return Scaffold(
        backgroundColor: context.mini.paper,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: MiniColors.warn
                        .withValues(alpha: context.isDarkMini ? 0.18 : 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(MiniIcons.offline,
                      size: 32, color: MiniColors.warn),
                ),
                const SizedBox(height: 26),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.outfit(
                    color: context.mini.inkSoft,
                    fontSize: 15,
                    height: 1.45,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 30),
                MiniButton(
                  label: 'Retry',
                  onPressed: _loadIdentity,
                ),
                const SizedBox(height: 8),
                MiniButton(
                  label: 'Contact support',
                  style: MiniBtnStyle.ghost,
                  onPressed: _contactSupport,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final tabs = [
      HomeScreen(
        identity: identity,
        autoAction: _widgetAction,
        onActionConsumed: () => setState(() => _widgetAction = null),
        onSeeAll: () => setState(() => _currentIndex = 2),
      ),
      RoomsScreen(identity: identity),
      HistoryScreen(identity: identity),
      SettingsScreen(identity: identity),
    ];

    return Scaffold(
      backgroundColor: context.mini.paper,
      // Tabs scroll beneath the glass nav. Its height reaches them as
      // MediaQuery bottom padding, which each tab adds to its scroll inset.
      extendBody: true,
      body: Column(
        children: [
          const GlobalStatusBanner(),
          Expanded(
            // Keyed by user: a replaced identity gets fresh tabs rather than
            // ones still holding the old user's lists.
            child: KeyedSubtree(
              key: ValueKey(identity.id),
              child: IndexedStack(
                index: _currentIndex,
                children: tabs,
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _MiniBottomNav(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
      ),
    );
  }
}

class _MiniBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _MiniBottomNav({required this.currentIndex, required this.onTap});

  static const _items = [
    _NavItem(
        icon: MiniIcons.home, activeIcon: MiniIcons.homeActive, label: 'Home'),
    _NavItem(
        icon: MiniIcons.rooms,
        activeIcon: MiniIcons.roomsActive,
        label: 'Rooms'),
    _NavItem(
        icon: MiniIcons.history,
        activeIcon: MiniIcons.historyActive,
        label: 'History'),
    _NavItem(
        icon: MiniIcons.settings,
        activeIcon: MiniIcons.settingsActive,
        label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
        child: MiniGlass(
          radius: MiniRadius.pill,
          strong: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              children: List.generate(_items.length, (i) {
                final item = _items[i];
                final isActive = i == currentIndex;
                return Expanded(
                  child: _MiniNavTile(
                    icon: item.icon,
                    activeIcon: item.activeIcon,
                    label: item.label,
                    isActive: isActive,
                    onTap: () => onTap(i),
                  ),
                );
              }),
            ),
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
  const _NavItem(
      {required this.icon, required this.activeIcon, required this.label});
}

class _MiniNavTile extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _MiniNavTile({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final tone = isActive ? c.accent : c.inkFaint;
    // Announced as a tab that is (or isn't) the current one, not as a bare
    // label: a screen reader otherwise gives no hint these can be pressed.
    return Semantics(
      button: true,
      selected: isActive,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: isActive ? c.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(MiniRadius.pill),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(isActive ? activeIcon : icon, size: 22, color: tone),
              const SizedBox(height: 3),
              Text(
                label,
                style: GoogleFonts.outfit(
                  fontSize: 10.5,
                  height: 1.1,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                  color: tone,
                  letterSpacing: -0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
