import 'dart:async';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../Minigo/theme/mini_icons.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../theme.dart';

/// Optional lock that asks for the fingerprint, Face ID or device passcode
/// before MiniGo's screens are shown.
///
/// Off by default. It locks on a cold start and whenever the app has been in
/// the background for longer than [graceperiod]. The device passcode is an
/// allowed fallback, so a failed fingerprint never locks someone out of
/// their own phone.
class AppLock {
  AppLock._();

  static const prefKey = 'app_lock_enabled';

  /// How long MiniGo can stay in the background before it locks again. Covers
  /// quick app switches and the system pickers the app opens to send or save
  /// files, without asking again each time.
  static const graceperiod = Duration(seconds: 60);

  /// Whether the lock is switched on. Kept in memory so the lifecycle check
  /// never waits on storage.
  static bool _enabled = false;

  /// True while the lock screen should cover the app.
  static final ValueNotifier<bool> locked = ValueNotifier<bool>(false);

  /// Replaces the system prompt in tests.
  @visibleForTesting
  static Future<bool> Function(String reason)? authenticateOverride;

  /// Replaces the clock that times the background period in tests.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  static bool get isEnabled => _enabled;

  /// Reads the saved setting and locks straight away if it is on. Call before
  /// the first frame so the app never shows behind an open lock.
  static Future<void> initialize() async {
    _enabled = await _readSaved();
    locked.value = _enabled;
  }

  /// Turns the lock on or off. Callers verify the user first with
  /// [authenticate].
  static Future<void> setEnabled(bool on) async {
    _enabled = on;
    if (!on) locked.value = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKey, on);
    } catch (_) {
      // Storage unreachable: the setting still holds for this run.
    }
  }

  /// Locks only if the lock is switched on.
  static void lockIfEnabled() {
    if (_enabled) locked.value = true;
  }

  static void unlock() => locked.value = false;

  /// Whether this device has a fingerprint, Face ID or passcode to check.
  static Future<bool> isAvailable() async {
    try {
      return await LocalAuthentication().isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// Runs the system prompt. False on cancel, failure, or no lock set up.
  static Future<bool> authenticate({required String reason}) async {
    final override = authenticateOverride;
    if (override != null) return override(reason);
    try {
      return await LocalAuthentication().authenticate(
        localizedReason: reason,
        // If the app is sent to the background mid-prompt, retry on return
        // rather than failing.
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _readSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(prefKey) ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// Covers the app with [AppLockScreen] while [AppLock.locked] is true, and
/// hides the content in the app switcher when the app goes to the background.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  DateTime? _pausedAt;
  bool _hidden = false;
  bool _prompting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLock.locked.addListener(_onLockChanged);
    if (AppLock.locked.value) _onLockChanged();
  }

  @override
  void dispose() {
    AppLock.locked.removeListener(_onLockChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        _pausedAt = AppLock.clock();
        setState(() => _hidden = true);
      case AppLifecycleState.resumed:
        final pausedAt = _pausedAt;
        _pausedAt = null;
        setState(() => _hidden = false);
        if (pausedAt != null &&
            AppLock.clock().difference(pausedAt) > AppLock.graceperiod) {
          AppLock.lockIfEnabled();
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _onLockChanged() {
    if (!AppLock.locked.value) return;
    // Wait for the frame so the prompt is not raised during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (_prompting || !AppLock.locked.value || !mounted) return;
    setState(() => _prompting = true);
    final ok = await AppLock.authenticate(reason: 'Unlock MiniGo');
    if (!mounted) return;
    setState(() => _prompting = false);
    if (ok) AppLock.unlock();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppLock.locked,
      child: widget.child,
      builder: (context, locked, child) {
        if (!locked && !_hidden) return child!;
        return Stack(
          fit: StackFit.expand,
          children: [
            child!,
            if (locked)
              AppLockScreen(prompting: _prompting, onUnlock: _unlock)
            else
              // Blank in the app switcher; the content is still mounted.
              ColoredBox(color: context.mini.paper),
          ],
        );
      },
    );
  }
}

class AppLockScreen extends StatelessWidget {
  const AppLockScreen({
    super.key,
    required this.prompting,
    required this.onUnlock,
  });

  final bool prompting;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.mini.paper,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: context.mini.inkSoft.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(MiniIcons.biometric,
                      size: 32, color: context.mini.inkSoft),
                ),
                const SizedBox(height: 26),
                Text(
                  'MiniGo is locked',
                  textAlign: TextAlign.center,
                  style: MiniText.title,
                ),
                const SizedBox(height: 12),
                Text(
                  'Use your fingerprint, Face ID or device passcode to open it.',
                  textAlign: TextAlign.center,
                  style: MiniText.bodySoft,
                ),
                const SizedBox(height: 30),
                MiniButton(
                  label: 'Unlock',
                  loading: prompting,
                  onPressed: onUnlock,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
