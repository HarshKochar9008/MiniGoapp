import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/features/receive/save_file.dart';

/// Saving on Android goes out over `minigo/native_save` because neither the
/// public Downloads folder nor the gallery is writable by path on API 29+.
/// These pin the channel contract — the Dart side has no other way to fail
/// visibly, and a silent break here loses the file after a full download and
/// decrypt.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('minigo/native_save');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tmp;
  late File source;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tmp = Directory.systemTemp.createTempSync('minigo_save_test');
    source = File('${tmp.path}/report.pdf')..writeAsStringSync('bytes');
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
    tmp.deleteSync(recursive: true);
  });

  test('hands the path and resolved mime type to the platform', () async {
    MethodCall? seen;
    messenger.setMockMethodCallHandler(channel, (call) async {
      seen = call;
      return 'content://media/external_primary/downloads/42';
    });

    final saved = await saveFileToDevice(source, 'report.pdf');

    expect(saved.label, 'Downloads');
    // The MediaStore row comes back as the handle the Open button views.
    expect(saved.open, 'content://media/external_primary/downloads/42');
    expect(seen!.method, 'saveToMediaStore');
    expect(seen!.arguments['sourcePath'], source.path);
    expect(seen!.arguments['fileName'], 'report.pdf');
    expect(seen!.arguments['mimeType'], 'application/pdf');
    expect(seen!.arguments['kind'], 'download');
  });

  test('an image lands in the gallery with a handle Open can view', () async {
    MethodCall? seen;
    messenger.setMockMethodCallHandler(channel, (call) async {
      seen = call;
      return 'content://media/external_primary/images/media/7';
    });
    final photo = File('${tmp.path}/holiday.jpg')..writeAsStringSync('bytes');

    final saved = await saveFileToDevice(photo, 'holiday.jpg');

    // The exact row, not the gallery's front page — that was the whole point
    // of taking the insert away from the plugin.
    expect(saved.open, 'content://media/external_primary/images/media/7');
    expect(saved.label, 'Gallery (MiniGo album)');
    expect(seen!.arguments['kind'], 'image');
    expect(seen!.arguments['mimeType'], 'image/jpeg');
  });

  test('a video is filed as video, not as an image', () async {
    MethodCall? seen;
    messenger.setMockMethodCallHandler(channel, (call) async {
      seen = call;
      return 'content://media/external_primary/video/media/9';
    });
    final clip = File('${tmp.path}/clip.mp4')..writeAsStringSync('bytes');

    await saveFileToDevice(clip, 'clip.mp4');

    expect(seen!.arguments['kind'], 'video');
  });

  test('offers no Open for a legacy path the viewer cannot read', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => '/storage/emulated/0/Download/report.pdf',
    );

    expect((await saveFileToDevice(source, 'report.pdf')).open, isNull);
  });

  test('sanitizes the sender-chosen name before it reaches the platform',
      () async {
    MethodCall? seen;
    messenger.setMockMethodCallHandler(channel, (call) async {
      seen = call;
      return 'Downloads';
    });

    await saveFileToDevice(source, '../../../etc/passwd.txt');

    final name = seen!.arguments['fileName'] as String;
    expect(name.contains('/'), isFalse);
    expect(name.contains('..'), isFalse);
  });

  test('surfaces a platform failure instead of reporting a save', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'save_failed', message: 'Disk full');
    });

    await expectLater(
      saveFileToDevice(source, 'report.pdf'),
      throwsA(isA<SaveFileException>()),
    );
  });

  test('Open hands the saved handle back to the platform', () async {
    MethodCall? seen;
    messenger.setMockMethodCallHandler(channel, (call) async {
      seen = call;
      return null;
    });

    await openSavedFile('content://media/external_primary/images/media/7');

    expect(seen!.method, 'openFile');
    expect(
      seen!.arguments['target'],
      'content://media/external_primary/images/media/7',
    );
  });

  test('iOS keeps the gallery plugin, not the Android channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var androidChannelCalled = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      androidChannelCalled = true;
      return 'Downloads';
    });

    // path_provider has no implementation under `flutter test`, so this throws
    // either way; the flag is what distinguishes the branches. Asserting on the
    // thrown type instead would pass even when the Android branch was taken.
    await saveFileToDevice(source, 'report.pdf').then<void>(
      (_) {},
      onError: (_) {},
    );

    expect(androidChannelCalled, isFalse);
  });
}
