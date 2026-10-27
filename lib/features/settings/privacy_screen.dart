import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../Minigo/theme/mini_icons.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../../core/app_reset.dart';
import '../../core/constants.dart';
import '../../core/contacts/contact_aliases.dart';
import '../../core/contacts/recent_recipients.dart';
import '../../core/crypto/e2e_crypto.dart';
import '../../core/storage/local_cache.dart';
import '../../core/supabase_config.dart';
import '../../core/theme.dart';
import '../identity/identity_service.dart';
import '../transfer/transfer_service.dart';
import 'app_facts.dart';
import 'legal_screens.dart';
import 'settings_components.dart';
import 'settings_links.dart';

enum _KeyStatus { stored, missing, unknown }

class PrivacyScreen extends StatefulWidget {
  final UserIdentity identity;

  const PrivacyScreen({super.key, required this.identity});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  // Live facts about this device, null until loaded.
  int? _cacheBytes;
  bool _cacheUnavailable = false;
  PendingUploadJob? _pendingUpload;
  bool _pendingLoaded = false;
  _KeyStatus? _keyStatus;

  @override
  void initState() {
    super.initState();
    _refreshCache();
    _refreshPendingUpload();
    _refreshKeyStatus();
  }

  Future<void> _refreshCache() async {
    try {
      final bytes = await LocalCache.measure();
      if (!mounted) return;
      setState(() {
        _cacheBytes = bytes;
        _cacheUnavailable = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cacheBytes = null;
        _cacheUnavailable = true;
      });
    }
  }

  Future<void> _refreshPendingUpload() async {
    PendingUploadJob? job;
    try {
      job = await TransferService.getPendingUploadJob(
        senderId: widget.identity.id,
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _pendingUpload = job;
      _pendingLoaded = true;
    });
  }

  Future<void> _refreshKeyStatus() async {
    var status = _KeyStatus.unknown;
    try {
      final prefs = await SharedPreferences.getInstance();
      final authUid = prefs.getString(AppConstants.prefAuthUid) ??
          (SupabaseConfig.isInitialized
              ? SupabaseConfig.client.auth.currentUser?.id
              : null);
      if (authUid != null) {
        status = await E2ECrypto.hasPrivateKey(authUid)
            ? _KeyStatus.stored
            : _KeyStatus.missing;
      }
    } catch (_) {
      // Secure storage unreachable — shown as "Unavailable".
    }
    if (mounted) setState(() => _keyStatus = status);
  }

  void _push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  /// Local cleanup removes the temp copies and resume state an upload is
  /// reading from, so it has to wait until no send is running.
  bool _blockedBySend() {
    if (!TransferService.isSendInFlight) return false;
    showMiniSnack(
        context, 'A send is in progress. Try again once it finishes.');
    return true;
  }

  static void _ensureNoSendStarted() {
    if (TransferService.isSendInFlight) {
      throw const MiniActionError(
        'A send just started. Try again once it finishes.',
      );
    }
  }

  String get _secureStoreName => defaultTargetPlatform == TargetPlatform.iOS
      ? 'the iOS Keychain'
      : 'storage protected by the Android Keystore';

  static String _modeLabel(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'System',
      };

  // ── Destructive actions ────────────────────────────────────────────────

  Future<void> _clearCache() async {
    if (_blockedBySend()) return;
    final bytes = _cacheBytes;
    if (bytes == 0) {
      showMiniSnack(context, 'The cache is already empty');
      return;
    }
    final size = bytes == null ? null : TransferService.formatFileSize(bytes);
    var freed = 0;
    final done = await showMiniConfirmSheet(
      context,
      icon: MiniIcons.storage,
      title: 'Clear local cache?',
      message: size == null
          ? 'Removes the temporary files MiniGo creates while sending and '
              'receiving.'
          : 'Frees up $size of temporary files MiniGo creates while sending '
              'and receiving.',
      impact: const [
        MiniImpactGroup('Removed from this device', MiniImpact.removed, [
          'Temporary copies of files you’ve downloaded',
          'Encrypted copies made for uploading',
          'Copies of files you picked or shared to send',
        ]),
        MiniImpactGroup('Not affected', MiniImpact.kept, [
          'Files you’ve saved to Photos, Downloads, or Files',
          'Your sharing code, contacts, and settings',
          'Anything stored on MiniGo’s servers',
        ]),
      ],
      warning: _pendingUpload == null
          ? null
          : 'You have an unfinished send. Its files may be in this cache, so '
              'you might not be able to resume it afterwards.',
      confirmLabel: 'Clear cache',
      onConfirm: () async {
        _ensureNoSendStarted();
        freed = await LocalCache.clear();
      },
    );
    if (!mounted) return;
    unawaited(_refreshCache());
    if (done) {
      showMiniSnack(
        context,
        freed > 0
            ? 'Freed ${TransferService.formatFileSize(freed)}'
            : 'Cache cleared',
      );
    }
  }

  Future<void> _resetPreferences() async {
    final current = ThemeController.themeMode.value;
    const fallback = ThemeController.defaultMode;
    if (current == fallback) {
      showMiniSnack(context, 'Preferences are already at their defaults');
      return;
    }
    final done = await showMiniConfirmSheet(
      context,
      icon: MiniIcons.preferences,
      title: 'Reset app preferences?',
      message: 'Appearance goes back to ${_modeLabel(fallback)}, MiniGo’s '
          'default.',
      impact: [
        MiniImpactGroup('Reset on this device', MiniImpact.changed, [
          'Appearance: ${_modeLabel(current)} → ${_modeLabel(fallback)}',
        ]),
        const MiniImpactGroup('Not affected', MiniImpact.kept, [
          'Your sharing code, nickname, and contacts',
          'Transfers and files you’ve saved',
          'Notification permission — change it in your phone’s Settings',
        ]),
      ],
      confirmLabel: 'Reset preferences',
      onConfirm: ThemeController.reset,
    );
    if (done && mounted) showMiniSnack(context, 'Preferences reset');
  }

  Future<void> _discardPendingUpload() async {
    if (_blockedBySend()) return;
    final job = _pendingUpload;
    if (job == null) {
      showMiniSnack(context, 'There are no unfinished sends');
      return;
    }
    final count = job.files.length;
    final files = count == 1 ? '1 file' : '$count files';
    final code = job.receiverCode;
    final done = await showMiniConfirmSheet(
      context,
      icon: MiniIcons.upload,
      title: 'Discard unfinished send?',
      message: 'A send of $files${code == null ? '' : ' to ${fmtCode(code)}'} '
          'didn’t finish. MiniGo kept it so you could resume it from Send '
          'Files.',
      impact: [
        const MiniImpactGroup('Removed from this device', MiniImpact.removed, [
          'The saved progress for this send',
        ]),
        MiniImpactGroup('On MiniGo’s servers', MiniImpact.changed, [
          'The transfer is marked as failed, so the recipient isn’t left '
              'waiting',
          'Anything already uploaded is removed when the transfer expires, '
              '${AppFacts.transferLifetime} after it started',
        ]),
        const MiniImpactGroup('Not affected', MiniImpact.kept, [
          'Your original files',
        ]),
      ],
      confirmLabel: 'Discard send',
      onConfirm: () async {
        _ensureNoSendStarted();
        await TransferService.discardPendingUploadJob(
          senderId: widget.identity.id,
        );
        await LocalCache.clearUploadResumeState();
      },
    );
    if (!mounted) return;
    unawaited(_refreshPendingUpload());
    if (done) showMiniSnack(context, 'Unfinished send discarded');
  }

  Future<void> _resetLocalData() async {
    if (_blockedBySend()) return;
    final job = _pendingUpload;
    final bytes = _cacheBytes;
    final done = await showMiniConfirmSheet(
      context,
      icon: MiniIcons.restart,
      title: 'Reset local app data?',
      message: 'Clears what MiniGo keeps on this device. You’ll keep your '
          'sharing code, so people can still send you files.',
      impact: [
        MiniImpactGroup('Removed from this device', MiniImpact.removed, [
          bytes == null || bytes == 0
              ? 'Temporary files'
              : 'Temporary files (${TransferService.formatFileSize(bytes)})',
          if (job != null)
            'Your unfinished send — the recipient will see it as failed',
          'Recent recipients and contact names you’ve saved',
          'Download history for received files',
          'App preferences',
        ]),
        MiniImpactGroup('Not affected', MiniImpact.kept, [
          'Your sharing code, nickname, and encryption key',
          'Files you’ve saved to Photos, Downloads, or Files',
          job == null
              ? 'Transfers on MiniGo’s servers'
              : 'Your other transfers on MiniGo’s servers',
        ]),
      ],
      confirmLabel: 'Reset local data',
      onConfirm: () async {
        _ensureNoSendStarted();
        await TransferService.discardPendingUploadJob(
          senderId: widget.identity.id,
        );
        await LocalCache.clear();
        await LocalCache.clearUploadResumeState();
        await RecentRecipients.clear();
        await ContactAliases.clear();
        await _clearDownloadHistory();
        await ThemeController.reset();
      },
    );
    if (!mounted) return;
    unawaited(_refreshCache());
    unawaited(_refreshPendingUpload());
    if (done) showMiniSnack(context, 'Local app data reset');
  }

  static Future<void> _clearDownloadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs
        .getKeys()
        .where((k) => k.startsWith(AppConstants.prefDownloadedFilesPrefix))
        .toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  Future<void> _deleteAccount() async {
    if (_blockedBySend()) return;
    await showMiniConfirmSheet(
      context,
      icon: MiniIcons.signOut,
      title: 'Sign out and delete account?',
      message: 'MiniGo accounts are anonymous, so there’s no way to sign back '
          'in. Your code ${fmtCode(widget.identity.shortCode)} will stop '
          'working for good.',
      impact: [
        MiniImpactGroup('On MiniGo’s servers', MiniImpact.changed, [
          'Your code is deactivated — no one can send to it again',
          'Your nickname and notification token are erased',
          'Files already sent to you still expire '
              '${AppFacts.transferLifetime} after they were sent',
        ]),
        const MiniImpactGroup('Removed from this device', MiniImpact.removed, [
          'Your code, encryption key, history, and settings',
        ]),
        const MiniImpactGroup('Not affected', MiniImpact.kept, [
          'Files you’ve saved to Photos, Downloads, or Files',
        ]),
      ],
      footnote: 'The deactivated code is kept on record so it’s never given '
          'to anyone else.',
      confirmLabel: 'Sign out and delete',
      requiresConnection: true,
      onConfirm: () async {
        _ensureNoSendStarted();
        try {
          // Relaunches the app on success, replacing this screen.
          await AppReset.clearLocalDataAndRelaunchUi(
            userId: widget.identity.id,
            requireServerRetirement: true,
          );
        } on AccountRetirementException catch (e) {
          throw MiniActionError(e.toString());
        }
      },
    );
  }

  // ── Explanations ───────────────────────────────────────────────────────

  void _showAccountSecurity() {
    final created = SupabaseConfig.isInitialized
        ? DateTime.tryParse(
            SupabaseConfig.client.auth.currentUser?.createdAt ?? '',
          )
        : null;
    showMiniInfoSheet(
      context,
      icon: MiniIcons.account,
      title: 'Anonymous account',
      message: 'MiniGo never asks for your name, email address, or phone '
          'number, and there’s no password to remember or leak. The first '
          'time you opened the app, it created an anonymous account for this '
          'device.',
      children: [
        MiniSheetDetails(rows: [
          ('Sharing code', fmtCode(widget.identity.shortCode)),
          ('Sign-in', 'Anonymous'),
          if (created != null)
            (
              'Created',
              MaterialLocalizations.of(context)
                  .formatMediumDate(created.toLocal()),
            ),
        ]),
        const MiniSheetFact(
          icon: MiniIcons.warning,
          tint: MiniColors.warn,
          title: 'No account recovery',
          body: 'Without an email or password, an anonymous account can’t be '
              'restored. If you delete MiniGo or sign out, you’ll get a new '
              'sharing code.',
        ),
      ],
    );
  }

  void _showActiveSessions() {
    final platform =
        defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android';
    showMiniInfoSheet(
      context,
      icon: MiniIcons.device,
      title: 'Active sessions',
      message: 'Your account is signed in on this device only.',
      children: [
        MiniSheetDetails(
            rows: [('This device', '$platform · Current session')]),
        const MiniSheetText(
          'Anonymous accounts can’t be signed in on another phone, so there '
          'are no other sessions to review or end. To end this one, use Sign '
          'out and delete account.',
        ),
      ],
    );
  }

  void _showSecureStorage() {
    final status = _keyStatus;
    showMiniInfoSheet(
      context,
      icon: MiniIcons.key,
      title: 'Secure local storage',
      message: 'MiniGo creates a private encryption key on this device and '
          'keeps it in $_secureStoreName. It never leaves your device — '
          'MiniGo’s servers only get the matching public key, which senders '
          'use to encrypt files for you.',
      children: [
        MiniSheetDetails(rows: [
          (
            'Encryption key',
            switch (status) {
              _KeyStatus.stored => 'Stored securely',
              _KeyStatus.missing => 'Not found',
              _KeyStatus.unknown || null => 'Couldn’t be checked',
            },
          ),
        ]),
        if (status == _KeyStatus.missing)
          const MiniSheetFact(
            icon: MiniIcons.warning,
            tint: MiniColors.warn,
            title: 'Files encrypted for you can’t be opened',
            body: 'Restart MiniGo to create a new key. Files encrypted for an '
                'earlier key can’t be recovered.',
          ),
        const MiniSheetText(
          'Your sharing code, preferences, and history are kept in MiniGo’s '
          'private app storage, which other apps can’t access.',
        ),
      ],
    );
  }

  void _showCodeExpiration() {
    showMiniInfoSheet(
      context,
      icon: MiniIcons.sharingCode,
      title: 'Sharing code expiration',
      message: 'Your personal sharing code doesn’t expire. It stays the same '
          'until you delete your account, so people you’ve shared it with can '
          'keep sending you files.',
      children: [
        MiniSheetFact(
          icon: MiniIcons.timer,
          title: 'Unused codes',
          body: 'If MiniGo isn’t opened on this device for '
              '${AppFacts.inactiveCodeRetention}, the code may be retired '
              'automatically.',
        ),
        MiniSheetFact(
          icon: MiniIcons.rooms,
          title: 'Room codes are temporary',
          body: 'A room closes ${AppFacts.roomLifetimes} after it’s created, '
              'depending on what its creator chose.',
        ),
        const MiniSheetFact(
          icon: MiniIcons.lock,
          title: 'Your code only lets people send',
          body: 'Someone with your code can send you files, but can’t see '
              'your transfers or anything you’ve received.',
        ),
      ],
    );
  }

  void _showFileAvailability() {
    showMiniInfoSheet(
      context,
      icon: MiniIcons.cloud,
      title: 'File availability',
      message: 'Files you send are held in MiniGo’s cloud storage so the '
          'recipient can download them, for ${AppFacts.transferLifetime} '
          'after sending.',
      children: [
        const MiniSheetFact(
          icon: MiniIcons.download,
          title: 'Downloading doesn’t remove them early',
          body: 'The recipient can download again until the transfer expires.',
        ),
        const MiniSheetFact(
          icon: MiniIcons.rooms,
          title: 'Rooms close sooner',
          body: 'Files sent in a room are available until the room closes.',
        ),
        MiniSheetFact(
          icon: MiniIcons.file,
          title: 'Size limits',
          body: 'Up to ${AppFacts.maxFiles} files per transfer, '
              '${AppFacts.maxFileSize} each.',
        ),
      ],
    );
  }

  void _showTransferExpiration() {
    showMiniInfoSheet(
      context,
      icon: MiniIcons.timer,
      title: 'Transfer expiration',
      message: 'Every transfer expires ${AppFacts.transferLifetime} after it’s '
          'sent — or when its room closes, if that’s sooner. After that:',
      children: [
        const MiniSheetFact(
          icon: MiniIcons.blocked,
          title: 'It can’t be downloaded',
          body: 'Expired transfers disappear from Received and can no longer '
              'be opened.',
        ),
        const MiniSheetFact(
          icon: MiniIcons.delete,
          title: 'Its files are removed from storage',
          body: 'MiniGo’s server cleanup deletes expired files from cloud '
              'storage.',
        ),
        MiniSheetFact(
          icon: MiniIcons.retention,
          title: 'Its record is cleared later',
          body: 'File names, sizes, and delivery status are removed '
              '${AppFacts.recordRetention} after sending.',
        ),
      ],
    );
  }

  void _showAccessControls() {
    showMiniInfoSheet(
      context,
      icon: MiniIcons.lock,
      title: 'File access controls',
      message: 'Each transfer belongs to two people: the sender and the '
          'recipient. MiniGo’s server rules stop everyone else — including '
          'other MiniGo users — from seeing the transfer or downloading its '
          'files.',
      children: const [
        MiniSheetFact(
          icon: MiniIcons.timer,
          title: 'Short-lived download links',
          body: 'Links to download a file are created on request and stop '
              'working after an hour.',
        ),
        MiniSheetFact(
          icon: MiniIcons.sharingCode,
          title: 'Share your code with care',
          body: 'Anyone with your code can send you files, so share it with '
              'people you want to hear from.',
        ),
      ],
    );
  }

  void _showTransportPrivacy() {
    showMiniInfoSheet(
      context,
      icon: MiniIcons.encrypted,
      title: 'Upload and download privacy',
      message: 'When the recipient’s app supports it — as current versions of '
          'MiniGo do — files are encrypted on the sender’s phone before '
          'upload. Only the recipient’s device holds the key to open them; '
          'MiniGo’s servers store data they can’t read.',
      children: const [
        MiniSheetFact(
          icon: MiniIcons.warning,
          title: 'Never unencrypted without asking',
          body: 'If a recipient can’t receive encrypted files, the sender is '
              'asked before anything is sent without encryption.',
        ),
        MiniSheetFact(
          icon: MiniIcons.lock,
          title: 'Encrypted connections',
          body: 'Uploads and downloads always travel over HTTPS.',
        ),
        MiniSheetFact(
          icon: MiniIcons.success,
          title: 'Checked for tampering',
          body: 'Every download is checked against a SHA-256 fingerprint of '
              'the original file.',
        ),
        MiniSheetFact(
          icon: MiniIcons.info,
          title: 'What isn’t encrypted',
          body: 'File names, sizes, and transfer times are visible to '
              'MiniGo’s servers so transfers can be delivered.',
        ),
      ],
    );
  }

  void _showHowSharingWorks() {
    showMiniInfoSheet(
      context,
      icon: MiniIcons.howItWorks,
      title: 'How file sharing works',
      children: [
        MiniSheetSteps(steps: [
          (
            'Share your code',
            'Give your ${AppConstants.codeLength}-character code, or show its '
                'QR code, to the person sending you files.',
          ),
          (
            'They pick files and send',
            'They enter your code and choose up to ${AppFacts.maxFiles} '
                'files. MiniGo encrypts them on their phone, then uploads '
                'them.',
          ),
          (
            'You download',
            'The files appear under Received on your Home screen, ready to '
                'download for ${AppFacts.transferLifetime}.',
          ),
        ]),
        const MiniSheetText(
          'No account, email, or phone number is needed on either side.',
        ),
      ],
    );
  }

  void _showDataRetention() {
    showMiniInfoSheet(
      context,
      icon: MiniIcons.retention,
      title: 'Data retention',
      message: 'What MiniGo stores, and for how long.',
      children: [
        const _SheetLabel('On MiniGo’s servers'),
        MiniSheetFact(
          icon: MiniIcons.cloud,
          title: 'Files you send',
          body: '${AppFacts.transferLifetime}, or until the room closes. '
              'Downloading doesn’t remove them sooner.',
        ),
        MiniSheetFact(
          icon: MiniIcons.document,
          title: 'Transfer records',
          body: 'File names, sizes, sender, recipient, and status — kept for '
              '${AppFacts.recordRetention}.',
        ),
        const MiniSheetFact(
          icon: MiniIcons.account,
          title: 'Nickname and notification token',
          body: 'Until you change them or delete your account.',
        ),
        MiniSheetFact(
          icon: MiniIcons.sharingCode,
          title: 'Sharing code and public key',
          body: 'While your account is in use. A deleted account’s code is '
              'kept deactivated so it’s never reused, and codes unused for '
              '${AppFacts.inactiveCodeRetention} may be retired automatically.',
        ),
        const MiniSheetFact(
          icon: MiniIcons.bug,
          title: 'Crash reports',
          body: 'Sent to Firebase Crashlytics if the app crashes, with your '
              'account ID and code, and kept under Google’s retention policy.',
        ),
        const _SheetLabel('On this device'),
        MiniSheetFact(
          icon: MiniIcons.key,
          title: 'Encryption key',
          body: 'In $_secureStoreName until you delete your account.',
        ),
        const MiniSheetFact(
          icon: MiniIcons.preferences,
          title: 'Code, nickname, and settings',
          body: 'Until you delete your account.',
        ),
        const MiniSheetFact(
          icon: MiniIcons.rooms,
          title: 'Recent recipients and contact names',
          body: 'Until you reset local app data. They’re never sent to '
              'MiniGo.',
        ),
        const MiniSheetFact(
          icon: MiniIcons.storage,
          title: 'Temporary files',
          body: 'Until you clear the cache, or your phone does.',
        ),
      ],
    );
  }

  void _showSecurityPractices() {
    showMiniInfoSheet(
      context,
      icon: MiniIcons.securityPractices,
      title: 'Security practices',
      message: 'How MiniGo protects your files and account.',
      children: [
        const MiniSheetFact(
          icon: MiniIcons.encrypted,
          title: 'End-to-end encryption',
          body: 'Each file is encrypted with AES-256-GCM under its own random '
              'key, which is sealed to the recipient’s X25519 public key. Only '
              'their device can unseal it.',
        ),
        MiniSheetFact(
          icon: MiniIcons.key,
          title: 'Keys stay on your device',
          body: 'Your private key is kept in $_secureStoreName and is never '
              'uploaded.',
        ),
        const MiniSheetFact(
          icon: MiniIcons.success,
          title: 'Tamper detection',
          body: 'Encrypted files are authenticated piece by piece, and every '
              'download is checked against a SHA-256 fingerprint.',
        ),
        const MiniSheetFact(
          icon: MiniIcons.lock,
          title: 'Encrypted connections',
          body: 'All traffic to MiniGo’s servers uses HTTPS.',
        ),
        const MiniSheetFact(
          icon: MiniIcons.shield,
          title: 'Strict access rules',
          body: 'Server-side rules limit each transfer to its sender and '
              'recipient, and download links expire after an hour.',
        ),
        const MiniSheetFact(
          icon: MiniIcons.blocked,
          title: 'Limits on code lookups',
          body: 'Looking up codes is rate-limited, so codes can’t be guessed '
              'at scale.',
        ),
      ],
    );
  }

  // ── Layout ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return MiniSettingsPage(
      title: 'Privacy & Security',
      children: [
        const _OverviewCard(),
        _securityAndAccount(),
        _fileSharing(),
        _dataAndDevice(),
        _privacyInformation(),
      ],
    );
  }

  Widget _securityAndAccount() {
    final status = _keyStatus;
    return MiniSettingsSection(
      title: 'Security & account',
      children: [
        MiniSettingsRow(
          icon: MiniIcons.account,
          title: 'Account security',
          subtitle: 'No email, phone number, or password',
          value: 'Anonymous',
          onTap: _showAccountSecurity,
        ),
        MiniSettingsRow(
          icon: MiniIcons.device,
          title: 'Active sessions',
          value: 'This device',
          onTap: _showActiveSessions,
        ),
        MiniSettingsRow(
          icon: MiniIcons.key,
          title: 'Secure local storage',
          subtitle: 'Your encryption key never leaves this device',
          trailing: status == null ? const MiniValueSkeleton() : null,
          value: switch (status) {
            _KeyStatus.stored => 'Protected',
            _KeyStatus.missing => 'No key',
            _KeyStatus.unknown => 'Unavailable',
            null => null,
          },
          valueColor: switch (status) {
            _KeyStatus.stored => MiniColors.success,
            _KeyStatus.missing => MiniColors.warn,
            _ => null,
          },
          onTap: _showSecureStorage,
        ),
        MiniSettingsRow(
          icon: MiniIcons.signOut,
          title: 'Sign out and delete account',
          subtitle: 'Permanently deactivates your code',
          destructive: true,
          onTap: _deleteAccount,
        ),
      ],
    );
  }

  Widget _fileSharing() {
    return MiniSettingsSection(
      title: 'File sharing & privacy',
      children: [
        MiniSettingsRow(
          icon: MiniIcons.sharingCode,
          title: 'Sharing code expiration',
          subtitle: 'Your code stays the same until you delete your account.',
          value: 'No expiry',
          onTap: _showCodeExpiration,
        ),
        MiniSettingsRow(
          icon: MiniIcons.cloud,
          title: 'File availability',
          subtitle: 'Files can be downloaded for '
              '${AppFacts.transferLifetime} after they’re sent.',
          onTap: _showFileAvailability,
        ),
        MiniSettingsRow(
          icon: MiniIcons.timer,
          title: 'Transfer expiration',
          subtitle: 'Expired files are removed from storage; records after '
              '${AppFacts.recordRetention}.',
          onTap: _showTransferExpiration,
        ),
        MiniSettingsRow(
          icon: MiniIcons.lock,
          title: 'File access controls',
          subtitle: 'Only the sender and recipient can open a transfer.',
          onTap: _showAccessControls,
        ),
        MiniSettingsRow(
          icon: MiniIcons.encrypted,
          title: 'Upload and download privacy',
          subtitle: 'Encrypted before upload when the recipient supports it.',
          onTap: _showTransportPrivacy,
        ),
      ],
    );
  }

  Widget _dataAndDevice() {
    final pending = _pendingUpload;
    final cacheBytes = _cacheBytes;
    return MiniSettingsSection(
      title: 'Data & device',
      footer: 'These actions clear data on this device. Your sharing code '
          'stays the same.',
      children: [
        MiniSettingsRow(
          icon: MiniIcons.storage,
          title: 'Clear local cache',
          subtitle: 'Temporary files from sending and receiving',
          trailing: cacheBytes == null && !_cacheUnavailable
              ? const MiniValueSkeleton(width: 46)
              : null,
          value: _cacheUnavailable
              ? 'Unavailable'
              : cacheBytes == null
                  ? null
                  : cacheBytes == 0
                      ? 'Empty'
                      : TransferService.formatFileSize(cacheBytes),
          onTap: _clearCache,
        ),
        ValueListenableBuilder<ThemeMode>(
          valueListenable: ThemeController.themeMode,
          builder: (context, mode, _) => MiniSettingsRow(
            icon: MiniIcons.preferences,
            title: 'Reset app preferences',
            subtitle: 'Return appearance to its default',
            value: _modeLabel(mode),
            onTap: _resetPreferences,
          ),
        ),
        MiniSettingsRow(
          icon: MiniIcons.upload,
          title: 'Clear pending uploads',
          subtitle: 'Discard an unfinished send saved on this device',
          trailing: _pendingLoaded ? null : const MiniValueSkeleton(width: 40),
          value: !_pendingLoaded
              ? null
              : pending == null
                  ? 'None'
                  : pending.files.length == 1
                      ? '1 file'
                      : '${pending.files.length} files',
          onTap: _discardPendingUpload,
        ),
        MiniSettingsRow(
          icon: MiniIcons.restart,
          title: 'Reset local app data',
          subtitle: 'Clear everything on this device except your code',
          destructive: true,
          onTap: _resetLocalData,
        ),
      ],
    );
  }

  Widget _privacyInformation() {
    return MiniSettingsSection(
      title: 'Privacy information',
      children: [
        MiniSettingsRow(
          icon: MiniIcons.howItWorks,
          title: 'How file sharing works',
          onTap: _showHowSharingWorks,
        ),
        MiniSettingsRow(
          icon: MiniIcons.retention,
          title: 'Data retention',
          subtitle: 'What’s stored, and for how long',
          onTap: _showDataRetention,
        ),
        MiniSettingsRow(
          icon: MiniIcons.shield,
          title: 'Privacy policy',
          onTap: () => _push(const PrivacyPolicyScreen()),
        ),
        MiniSettingsRow(
          icon: MiniIcons.securityPractices,
          title: 'Security practices',
          onTap: _showSecurityPractices,
        ),
        MiniSettingsRow(
          icon: MiniIcons.bug,
          title: 'Report a security issue',
          subtitle: AppConstants.supportEmail,
          accessory: MiniRowAccessory.external,
          onTap: () => emailSupport(
            context,
            subject: 'MiniGo security report',
            prompt: 'What did you find, and how can we reproduce it?',
          ),
        ),
      ],
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard();

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      padding: const EdgeInsets.all(18),
      decoration: miniCard(context, strong: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MiniIconPlate(
                icon: MiniIcons.encrypted,
                tint: c.accent,
                size: 44,
                iconSize: 21,
                radius: 11,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'Your privacy matters. Manage your security preferences and '
                  'understand how MiniGo handles your information.',
                  style: GoogleFonts.outfit(
                    fontSize: 15,
                    height: 1.45,
                    color: c.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const HairLine(),
          const SizedBox(height: 14),
          const MiniFactLine(
            icon: MiniIcons.check,
            tint: MiniColors.success,
            text: 'No email, phone number, or password',
          ),
          const SizedBox(height: 10),
          MiniFactLine(
            icon: MiniIcons.check,
            tint: MiniColors.success,
            text: 'Transfers expire after ${AppFacts.transferLifetime}',
          ),
          const SizedBox(height: 10),
          const MiniFactLine(
            icon: MiniIcons.check,
            tint: MiniColors.success,
            text: 'Only the sender and recipient can open a transfer',
          ),
        ],
      ),
    );
  }
}

/// Small caps divider between groups inside a sheet.
class _SheetLabel extends StatelessWidget {
  final String text;
  const _SheetLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Semantics(
          header: true,
          child: Text(
            text.toUpperCase(),
            style: MiniText.label.copyWith(
              color: context.mini.inkSoft,
              letterSpacing: 0.9,
            ),
          ),
        ),
      );
}
