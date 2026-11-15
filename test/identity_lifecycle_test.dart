import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/core/constants.dart';
import 'package:minigo/core/notifications/pending_push.dart';
import 'package:minigo/features/identity/identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local rules of the identity lifecycle that need no backend: what counts
/// as a saved identity, the persisted retirement queue, queued nickname
/// edits, and holding notification taps until the shell can open them.
/// (Supabase isn't initialized here, so every server call fails the way an
/// unreachable backend would, without touching the network.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IdentityService.debugSetIdentity(null, IdentityTrust.none);
  });

  tearDown(() {
    IdentityService.debugSetIdentity(null, IdentityTrust.none);
  });

  group('saved identity', () {
    test('needs the row id, short code and owning auth uid together', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.prefUserDbId: 'user-1',
        AppConstants.prefShortCode: 'A4X9K2',
        AppConstants.prefAuthUid: 'auth-1',
        AppConstants.prefNickname: '  Alex ',
      });
      final prefs = await SharedPreferences.getInstance();
      final identity = IdentityService.identityFromPrefs(prefs);
      expect(identity?.id, 'user-1');
      expect(identity?.shortCode, 'A4X9K2');
      expect(identity?.nickname, 'Alex');
    });

    test('a partial set from an interrupted write is no identity', () async {
      for (final missing in [
        AppConstants.prefUserDbId,
        AppConstants.prefShortCode,
        AppConstants.prefAuthUid,
      ]) {
        SharedPreferences.setMockInitialValues({
          AppConstants.prefUserDbId: 'user-1',
          AppConstants.prefShortCode: 'A4X9K2',
          AppConstants.prefAuthUid: 'auth-1',
        }..remove(missing));
        final prefs = await SharedPreferences.getInstance();
        expect(IdentityService.identityFromPrefs(prefs), isNull,
            reason: 'missing $missing');
      }
    });

    test('a blank nickname reads as none', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.prefUserDbId: 'user-1',
        AppConstants.prefShortCode: 'A4X9K2',
        AppConstants.prefAuthUid: 'auth-1',
        AppConstants.prefNickname: '   ',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(IdentityService.identityFromPrefs(prefs)?.nickname, isNull);
    });
  });

  group('retirement queue', () {
    test('queues each old auth uid once', () async {
      await IdentityService.queueRetirement('old-1');
      await IdentityService.queueRetirement('old-2');
      await IdentityService.queueRetirement('old-1');
      expect(await IdentityService.pendingRetirements(), ['old-2', 'old-1']);
    });

    test('keeps the queue when the server can’t be reached', () async {
      await IdentityService.queueRetirement('old-1');
      await IdentityService.flushPendingRetirements();
      expect(await IdentityService.pendingRetirements(), ['old-1']);
    });

    test('drops jobs the server sweep has long since covered', () async {
      SharedPreferences.setMockInitialValues({
        IdentityService.pendingRetirementsKey: jsonEncode([
          {'uid': 'ancient', 'since': 0},
          {
            'uid': 'recent',
            'since': DateTime.now().millisecondsSinceEpoch,
          },
        ]),
      });
      expect(await IdentityService.pendingRetirements(), ['recent']);
    });

    test('ignores a corrupt queue instead of failing', () async {
      SharedPreferences.setMockInitialValues({
        IdentityService.pendingRetirementsKey: 'not json',
      });
      expect(await IdentityService.pendingRetirements(), isEmpty);
    });
  });

  group('nickname', () {
    const identity = UserIdentity(id: 'user-1', shortCode: 'A4X9K2');

    test('an edit the server didn’t get is kept locally and queued', () async {
      // No auth uid saved: the edit must still not crash.
      SharedPreferences.setMockInitialValues({
        AppConstants.prefUserDbId: identity.id,
        AppConstants.prefShortCode: identity.shortCode,
      });
      IdentityService.debugSetIdentity(identity, IdentityTrust.verified);

      await IdentityService.setNickname('  Alex ');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConstants.prefNickname), 'Alex');
      expect(IdentityService.identityNotifier.value?.nickname, 'Alex');
      expect(IdentityService.isVerified, isTrue);
      final pending = jsonDecode(
        prefs.getString(IdentityService.pendingNicknameKey)!,
      ) as Map;
      expect(pending, {'id': 'user-1', 'nickname': 'Alex'});
    });

    test('removing it queues the removal too', () async {
      IdentityService.debugSetIdentity(
        const UserIdentity(id: 'user-1', shortCode: 'A4X9K2', nickname: 'A'),
        IdentityTrust.verified,
      );
      await IdentityService.setNickname('');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConstants.prefNickname), isNull);
      final pending = jsonDecode(
        prefs.getString(IdentityService.pendingNicknameKey)!,
      ) as Map;
      expect(pending, {'id': 'user-1', 'nickname': null});
    });

    test('a name typed before any identity goes to the first one created',
        () async {
      await IdentityService.setNicknameForFirstIdentity('  Alex ');
      final prefs = await SharedPreferences.getInstance();

      final taken = await IdentityService.takePendingNickname(prefs, identity);
      expect(taken?.nickname, 'Alex');
      expect(prefs.containsKey(IdentityService.firstNicknameKey), isFalse);
      // Re-queued as an ordinary edit, so a failed push is retried.
      final pending = jsonDecode(
        prefs.getString(IdentityService.pendingNicknameKey)!,
      ) as Map;
      expect(pending, {'id': 'user-1', 'nickname': 'Alex'});
    });

    test('an identity with a name of its own keeps it', () async {
      await IdentityService.setNicknameForFirstIdentity('Alex');
      final prefs = await SharedPreferences.getInstance();

      final taken = await IdentityService.takePendingNickname(
        prefs,
        const UserIdentity(id: 'user-1', shortCode: 'A4X9K2', nickname: 'Sam'),
      );
      expect(taken, isNull);
      expect(prefs.containsKey(IdentityService.firstNicknameKey), isFalse);
      expect(prefs.containsKey(IdentityService.pendingNicknameKey), isFalse);
    });

    test('an edit queued for the identity wins over the early name', () async {
      SharedPreferences.setMockInitialValues({
        IdentityService.firstNicknameKey: 'Alex',
        IdentityService.pendingNicknameKey:
            jsonEncode({'id': 'user-1', 'nickname': 'Sam'}),
      });
      final prefs = await SharedPreferences.getInstance();

      final taken = await IdentityService.takePendingNickname(prefs, identity);
      expect(taken?.nickname, 'Sam');
      expect(prefs.containsKey(IdentityService.firstNicknameKey), isFalse);
    });
  });

  group('reset', () {
    test('refuses to start an identity while resetting', () async {
      IdentityService.beginReset();
      addTearDown(IdentityService.endReset);
      expect(IdentityService.isResetting, isTrue);
      await expectLater(
        IdentityService.initialize(),
        throwsA(isA<IdentityResetInProgressException>()),
      );
    });

    test('a verified identity is handed out without asking the server',
        () async {
      const identity = UserIdentity(id: 'user-1', shortCode: 'A4X9K2');
      IdentityService.debugSetIdentity(identity, IdentityTrust.verified);
      expect(await IdentityService.initialize(), same(identity));
    });
  });

  group('notification taps', () {
    tearDown(PendingIncomingTransfer.clear);

    test('wait until a shell accepts them', () {
      final shell = Object();
      PendingIncomingTransfer.setFromRemoteMessage({'transfer_id': 't-1'});

      PendingIncomingTransfer.tryNavigateToReceive();
      expect(PendingIncomingTransfer.hasPending, isTrue);

      PendingIncomingTransfer.enableDelivery(shell);
      expect(PendingIncomingTransfer.canDeliver, isTrue);
      PendingIncomingTransfer.disableDelivery(shell);
      expect(PendingIncomingTransfer.canDeliver, isFalse);
      expect(PendingIncomingTransfer.hasPending, isTrue);
    });

    test('a shell being torn down can’t switch off its replacement', () {
      final oldShell = Object();
      final newShell = Object();
      PendingIncomingTransfer.enableDelivery(oldShell);
      PendingIncomingTransfer.enableDelivery(newShell);
      PendingIncomingTransfer.disableDelivery(oldShell);
      expect(PendingIncomingTransfer.canDeliver, isTrue);
      PendingIncomingTransfer.disableDelivery(newShell);
    });
  });
}
