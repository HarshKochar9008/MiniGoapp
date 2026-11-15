import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/core/theme.dart';
import 'package:minigo/features/qr/qr_widgets.dart';

void main() {
  setUpAll(() {
    dotenv.loadFromString(
        envString: 'SUPABASE_URL=https://example.supabase.co');
  });

  Future<List<MethodCall>> openSheet(WidgetTester tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                QrCodeSheet.show(context, 'A4X9K2', shareText: 'share me'),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return calls;
  }

  testWidgets('shows the code with Copy code and Share', (tester) async {
    await openSheet(tester);
    expect(find.text('Your QR code'), findsOneWidget);
    expect(find.text('A4X · 9K2'), findsOneWidget);
    expect(find.text('Copy code'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
  });

  testWidgets('Copy code copies, confirms in place, then resets',
      (tester) async {
    final calls = await openSheet(tester);
    await tester.tap(find.text('Copy code'));
    await tester.pump();

    final copy = calls.where((c) => c.method == 'Clipboard.setData');
    expect(copy, isNotEmpty);
    expect((copy.last.arguments as Map)['text'], 'A4X9K2');
    expect(find.text('Copied'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Copy code'), findsOneWidget);
  });

  testWidgets('the close button dismisses the sheet', (tester) async {
    await openSheet(tester);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Your QR code'), findsNothing);
  });
}
