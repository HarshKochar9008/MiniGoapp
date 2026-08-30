import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/features/receive/save_file.dart';

/// Saving a non-media file on Android goes out over `minigo/native_save`
/// because the public Downloads folder is not writable by path on API 29+.
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
      return 'Downloads';
    });

    final location = await saveFileToDevice(source, 'report.pdf');

    expect(location, 'Downloads');
    expect(seen!.method, 'saveToDownloads');
    expect(seen!.arguments['sourcePath'], source.path);
    expect(seen!.arguments['fileName'], 'report.pdf');
    expect(seen!.arguments['mimeType'], 'application/pdf');
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

  test('iOS keeps writing into the app documents directory', () async {
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
