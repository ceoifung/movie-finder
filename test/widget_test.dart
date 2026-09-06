import 'package:flutter_test/flutter_test.dart';
import 'package:movie_finder_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app boots to home screen (本地引擎无网络依赖)', (tester) async {
    await tester.pumpWidget(const CreatureFinderApp());
    await tester.pump();
    expect(find.textContaining('输入条件或点选生物标签开始搜索'), findsOneWidget);
    // 生物标签条应有内容（本地本体库）
    expect(find.text('丧尸'), findsOneWidget);
    expect(find.text('吸血鬼'), findsOneWidget);
  });
}
