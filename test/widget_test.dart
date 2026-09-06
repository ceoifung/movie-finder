import 'package:flutter_test/flutter_test.dart';
import 'package:movie_finder_app/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app boots to home screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const CreatureFinderApp());
    await tester.pump();
    expect(find.text('输入条件或点选生物标签开始搜索'), findsOneWidget);
  });
}
