// 真实网络冒烟测试（不在 CI 跑，本地验证引擎链路）：dart run tool/smoke_test.dart
import 'dart:convert';

import 'package:movie_finder_app/engine/aggregator.dart';

Future<void> main(List<String> args) async {
  final engine = Engine(EngineConfig());
  final queries = args.isNotEmpty ? args : ['巨型鲨鱼', '丧尸 90年代'];

  for (final q in queries) {
    print('\n========== 搜索「$q」==========');
    final r = await engine.search(SearchInput(q, country: 'ALL'));
    print('耗时 ${r.tookMs}ms，结果 ${r.results.length} 条');
    for (final s in r.sources) {
      final name = s.keys.first;
      final st = s.values.first as Map<String, dynamic>;
      print('  [$name] ${st['status']} ${st['results']}条 ${st['error'] ?? ''}');
    }
    for (final m in r.results.take(5)) {
      final free = m.offers.where((o) => o.kind == 'free').length;
      print('\n  ${m.title} (${m.year}) | ${m.originalTitle} | imdb:${m.ratings['imdb']}'
          ' | ${m.sources} | offers:${m.offers.length}(免费$free)');
      print('    poster: ${m.poster.substring(0, m.poster.length.clamp(0, 70))}');
      for (final l in m.webLinks.take(3)) {
        print('    [link] ${l.title.substring(0, l.title.length.clamp(0, 38))} -> ${l.url.substring(0, l.url.length.clamp(0, 60))}');
      }
    }
    print('\n(原始JSON预览) ${jsonEncode(r.queryEcho)}');
  }
}
