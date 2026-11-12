import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../Minigo/theme/mini_icons.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../../features/settings/settings_links.dart';
import '../theme.dart';
import 'app_security.dart';

/// Shows the app until [AppSecurity] restricts it, then [SecurityLockScreen]
/// in its place. Sits in `MaterialApp.builder`, above the navigator, so no
/// route can be pushed over the notice.
class SecurityGate extends StatelessWidget {
  const SecurityGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppSecurity.instance.restricted,
      child: child,
      builder: (context, restricted, child) =>
          restricted ? const SecurityLockScreen() : child!,
    );
  }
}

/// Asks for a reinstall once this copy of MiniGo can't be trusted. It names
/// no threat: the detail is in Crashlytics, and spelling it out here would
/// only tell someone which check to get around.
class SecurityLockScreen extends StatelessWidget {
  const SecurityLockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = defaultTargetPlatform == TargetPlatform.iOS
        ? 'the App Store'
        : 'Google Play';
    return Scaffold(
      backgroundColor: context.mini.paper,
      body: SafeArea(
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
                    color: MiniColors.danger
                        .withValues(alpha: context.isDarkMini ? 0.18 : 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(MiniIcons.shield,
                      size: 32, color: MiniColors.danger),
                ),
                const SizedBox(height: 26),
                Text(
                  'Reinstall MiniGo',
                  textAlign: TextAlign.center,
                  style: MiniText.title,
                ),
                const SizedBox(height: 12),
                Text(
                  'MiniGo couldn’t confirm that this copy of the app is '
                  'genuine and running unmodified, so it has stopped sending '
                  'and receiving files to keep them safe.\n\n'
                  'Delete MiniGo and install it again from $store. If this '
                  'keeps happening, contact support.',
                  textAlign: TextAlign.center,
                  style: MiniText.bodySoft,
                ),
                const SizedBox(height: 30),
                MiniButton(
                  label: 'Contact support',
                  style: MiniBtnStyle.ghost,
                  onPressed: () => emailSupport(
                    context,
                    subject: 'MiniGo asked me to reinstall it',
                    prompt: 'Where did you install MiniGo from?',
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
