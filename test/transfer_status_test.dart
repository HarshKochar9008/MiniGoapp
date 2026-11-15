import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/features/transfer/r2_storage.dart';
import 'package:minigo/features/transfer/transfer_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show FunctionException, FunctionsFetchException;

/// The transfer lifecycle model every screen and the send/resume logic share.
/// Pure Dart: no Supabase, no platform channels.
void main() {
  group('TransferStatus.parse', () {
    test('reads every stored value', () {
      for (final s in TransferStatus.values) {
        expect(TransferStatus.parse(s.dbValue), s);
      }
      expect(TransferStatus.parse(' Completed '), TransferStatus.completed);
    });

    test('null, empty and unknown read as pending', () {
      expect(TransferStatus.parse(null), TransferStatus.pending);
      expect(TransferStatus.parse(''), TransferStatus.pending);
      expect(TransferStatus.parse('cancelled'), TransferStatus.pending);
    });
  });

  group('TransferStatus.effective (client TTL)', () {
    final now = DateTime.utc(2026, 11, 13, 12);

    test('a transfer past its TTL is expired before the sweep stamps it', () {
      final old = now.subtract(TransferStatus.ttl + const Duration(minutes: 1));
      expect(
        TransferStatus.effective('completed', old.toIso8601String(), now: now),
        TransferStatus.expired,
      );
    });

    test('a young transfer keeps its stored status', () {
      final young = now.subtract(const Duration(hours: 1));
      expect(
        TransferStatus.effective('partial', young.toIso8601String(), now: now),
        TransferStatus.partial,
      );
    });

    test('a stored expired stays expired; an unparsable date is ignored', () {
      expect(TransferStatus.effective('expired', null, now: now),
          TransferStatus.expired);
      expect(TransferStatus.effective('pending', 'not a date', now: now),
          TransferStatus.pending);
    });

    test('effectiveOf reads a row, and the fetch helper rewrites status', () {
      final row = {
        'id': 't1',
        'status': 'pending',
        'created_at': now.subtract(const Duration(hours: 30)).toIso8601String(),
      };
      expect(TransferStatus.effectiveOf(row, now: now), TransferStatus.expired);
      expect(
        TransferService.withEffectiveStatus(row, now: now)['status'],
        'expired',
      );
      // The input row is not mutated.
      expect(row['status'], 'pending');
    });
  });

  group('capabilities', () {
    test('live progress only while the sender may still be uploading', () {
      expect(
        TransferStatus.values.where((s) => s.showLiveProgress).toSet(),
        {TransferStatus.pending, TransferStatus.uploading},
      );
    });

    test('uploads are refused once completed or expired', () {
      expect(
        TransferStatus.values.where((s) => !s.acceptsUploads).toSet(),
        {TransferStatus.completed, TransferStatus.expired},
      );
      expect(TransferStatus.failed.senderMayResume, isTrue);
      expect(TransferStatus.partial.senderMayResume, isTrue);
    });

    test('only an expired transfer is not downloadable', () {
      expect(
        TransferStatus.values.where((s) => !s.downloadable).toSet(),
        {TransferStatus.expired},
      );
    });

    test('abandon never overwrites a real outcome', () {
      expect(
        TransferStatus.values.where((s) => s.mayAbandon).toSet(),
        {
          TransferStatus.pending,
          TransferStatus.uploading,
          TransferStatus.failed,
        },
      );
    });

    test('history can hide exactly the settled transfers', () {
      expect(
        TransferStatus.values.where((s) => s.canHideFromHistory).toSet(),
        {
          TransferStatus.completed,
          TransferStatus.partial,
          TransferStatus.failed,
          TransferStatus.expired,
        },
      );
    });
  });

  group('client transitions', () {
    test('expired and completed are final for the client', () {
      for (final next in TransferStatus.values) {
        expect(TransferStatus.expired.canClientMoveTo(next), isFalse);
        expect(TransferStatus.completed.canClientMoveTo(next), isFalse);
      }
    });

    test('the client never writes expired or the legacy uploading', () {
      for (final from in TransferStatus.values) {
        expect(from.canClientMoveTo(TransferStatus.expired), isFalse);
        expect(from.canClientMoveTo(TransferStatus.uploading), isFalse);
      }
    });

    test('resume puts partial/failed back to pending; partial never fails', () {
      expect(TransferStatus.partial.canClientMoveTo(TransferStatus.pending),
          isTrue);
      expect(TransferStatus.failed.canClientMoveTo(TransferStatus.pending),
          isTrue);
      expect(TransferStatus.partial.canClientMoveTo(TransferStatus.failed),
          isFalse);
      expect(TransferStatus.failed.canClientMoveTo(TransferStatus.partial),
          isTrue);
    });

    test('a final write is guarded against completed and expired', () {
      expect(TransferStatus.protectedFrom(TransferStatus.completed),
          {TransferStatus.completed, TransferStatus.expired});
      expect(TransferStatus.protectedFrom(TransferStatus.pending),
          {TransferStatus.completed, TransferStatus.expired});
      expect(TransferStatus.protectedFrom(TransferStatus.failed), {
        TransferStatus.completed,
        TransferStatus.expired,
        TransferStatus.partial,
      });
    });
  });

  group('R2 signer failures', () {
    test('401/403/409/410 are refusals, never a Supabase fallback', () {
      for (final status in [401, 403, 409, 410]) {
        final e = R2Storage.classifyFailure(
          FunctionException(status: status, details: {'error': 'no'}),
          'r2-sign-upload',
        );
        expect(e, isA<R2RefusedException>());
        expect((e as R2RefusedException).status, status);
      }
      final upload409 = R2Storage.classifyFailure(
          const FunctionException(status: 409), 'r2-sign-upload');
      expect((upload409 as R2RefusedException).notAcceptingUploads, isTrue);
      final download410 = R2Storage.classifyFailure(
          const FunctionException(status: 410), 'r2-sign-download');
      expect((download410 as R2RefusedException).expired, isTrue);
    });

    test('not configured, 5xx and network failures mean "unavailable"', () {
      expect(
        R2Storage.classifyFailure(
          const FunctionException(
              status: 503, details: {'error': 'r2_not_configured'}),
          'r2-sign-upload',
        ),
        isA<R2SigningException>(),
      );
      expect(
        R2Storage.classifyFailure(
            const FunctionException(status: 500), 'r2-sign-download'),
        isA<R2SigningException>(),
      );
      expect(
        R2Storage.classifyFailure(
            const FunctionsFetchException(details: 'offline'), 'x'),
        isA<R2SigningException>(),
      );
      expect(
        R2Storage.classifyFailure(Exception('socket closed'), 'x'),
        isA<R2SigningException>(),
      );
    });
  });

  group('PendingUploadJob room fields', () {
    Map<String, dynamic> base() => {
          'sender_id': 's',
          'receiver_id': 'r',
          'transfer_id': 't',
          'files': [
            const PendingUploadFile(name: 'a', path: '/tmp/a', size: 1)
                .toJson(),
          ],
        };

    test('round-trip keeps the room', () {
      final job = PendingUploadJob.fromJson({
        ...base(),
        'room_id': 'room-1',
        'room_name': 'Team',
      })!;
      expect(job.roomId, 'room-1');
      expect(job.roomName, 'Team');
      final again = PendingUploadJob.fromJson(job.toJson())!;
      expect(again.roomId, 'room-1');
      expect(again.roomName, 'Team');
    });

    test('jobs saved before room fields load as direct sends', () {
      final job = PendingUploadJob.fromJson(base())!;
      expect(job.roomId, isNull);
      expect(job.roomName, isNull);
      expect(job.toJson().containsKey('room_id'), isFalse);
    });
  });
}
