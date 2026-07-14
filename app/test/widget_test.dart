import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pocketpad/main.dart';

void main() {
  testWidgets('接続画面が表示される', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PocketPadApp());

    expect(find.text('PocketPad'), findsOneWidget);
    expect(find.text('QRコードで接続'), findsOneWidget);
  });
}
