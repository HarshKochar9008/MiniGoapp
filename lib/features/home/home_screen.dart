import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/network/connection_status.dart';
import '../../core/native/native_share.dart';
import '../../zensend/theme/zen_theme.dart';
import '../../zensend/widgets/zen_widgets.dart';
import '../identity/identity_service.dart';
import '../send/send_screen.dart';

class HomeScreen extends StatefulWidget {
  final UserIdentity identity;
  const HomeScreen({super.key, required this.identity});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isOnline = true;
  late final VoidCallback _onConnectionChanged;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ConnectionStatus.instance.ensureStarted();
    _isOnline = ConnectionStatus.instance.online.value;
    _onConnectionChanged = () {
      final next = ConnectionStatus.instance.online.value;
      if (!mounted || next == _isOnline) return;
      setState(() => _isOnline = next);
    };
    ConnectionStatus.instance.online.addListener(_onConnectionChanged);
    unawaited(ConnectionStatus.instance.refresh());
  }

  @override
  void dispose() {
    ConnectionStatus.instance.online.removeListener(_onConnectionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ConnectionStatus.instance.refresh());
    }
  }

  void _copyCode() {
    Clipboard.setData(ClipboardData(text: widget.identity.shortCode));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Code copied')),
    );
  }

  void _shareCode() {
    NativeShareService.shareText(
      'Send me files on ZenSend using my code: ${widget.identity.shortCode}',
      subject: 'ZenSend invite',
    );
  }

  void _openSend() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SendScreen(identity: widget.identity),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final code = widget.identity.shortCode;

    return Scaffold(
      backgroundColor: ZenColors.paper,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('You are', style: ZenText.label),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              fmtCode(code),
                              style: ZenText.code.copyWith(fontSize: 22),
                            ),
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: _copyCode,
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(
                                  Icons.copy_rounded,
                                  size: 15,
                                  color: ZenColors.inkFaint,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Online status dot
                  GestureDetector(
                    onTap: _shareCode,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: _isOnline
                                  ? ZenColors.success
                                  : ZenColors.danger,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            _isOnline ? 'Online' : 'Offline',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: _isOnline ? ZenColors.success : ZenColors.danger,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const HairLine(indent: 20),

            // Large code card
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Code card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: ZenColors.blue600,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            'YOUR CODE',
                            style: ZenText.label.copyWith(
                              color: ZenColors.blue200,
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            fmtCode(code),
                            style: ZenText.codeLarge.copyWith(
                              color: ZenColors.paper,
                              letterSpacing: 4,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Expanded(
                                child: _OutlineBtn(
                                  icon: Icons.copy_rounded,
                                  label: 'Copy',
                                  onTap: _copyCode,
                                  dark: true,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _OutlineBtn(
                                  icon: Icons.share_rounded,
                                  label: 'Share',
                                  onTap: _shareCode,
                                  dark: true,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    // Info card
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14),
                      decoration: BoxDecoration(
                        color: ZenColors.blue50,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: ZenColors.blue200),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded,
                              size: 18, color: ZenColors.blue600),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Share this code so others can send you files. '
                              'Tap Send below to send files to someone else.',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: ZenColors.blue600,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: FloatingActionButton.extended(
          onPressed: _openSend,
          backgroundColor: ZenColors.blue600,
          foregroundColor: ZenColors.paper,
          elevation: 0,
          extendedPadding:
              const EdgeInsets.symmetric(horizontal: 28, vertical: 0),
          label: Text(
            'Send',
            style: GoogleFonts.inter(
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              fontSize: 15,
              color: ZenColors.paper,
            ),
          ),
          icon: const Icon(Icons.north_east_rounded, size: 18),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }
}

class _OutlineBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool dark;
  const _OutlineBtn({required this.icon, required this.label, required this.onTap, this.dark = false});

  @override
  Widget build(BuildContext context) {
    if (dark) {
      return GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.12)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 15, color: Colors.white.withOpacity(0.75)),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: Colors.white.withOpacity(0.75),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: ZenColors.paper,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ZenColors.divider),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: ZenColors.ink),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: ZenColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
