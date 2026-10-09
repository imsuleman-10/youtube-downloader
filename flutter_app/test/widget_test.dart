import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/main.dart';

void main() {
  testWidgets('SamTube app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SamTubeApp());
    expect(find.text('SamTube'), findsOneWidget);
  });
}
