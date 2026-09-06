import 'package:flutter_test/flutter_test.dart';
import 'package:movie_finder_app/engine/aggregator.dart';
import 'package:movie_finder_app/engine/models.dart';
import 'package:movie_finder_app/engine/t2s.dart';
import 'package:movie_finder_app/engine/taxonomy.dart';

void main() {
  group('taxonomy 查询解析', () {
    test('生物 + 类型 + 年代', () {
      final pq = parseQuery('恐怖片 巨型鲨鱼 90年代');
      expect(pq.creatures, contains('巨型鲨鱼'));
      expect(pq.genreZh, '恐怖');
      expect(pq.yearFrom, 1990);
      expect(pq.yearTo, 1999);
      expect(pq.searchTerms.first, 'shark');
      expect(pq.termsByLang['ja'], contains('メガシャーク'));
      expect(pq.termsByLang['ko'], contains('메가 샤크'));
      expect(pq.impliedGenreEn, isNull); // 已有显式类型
    });

    test('只有生物时用隐含类型', () {
      final pq = parseQuery('丧尸');
      expect(pq.creatures, ['丧尸']);
      expect(pq.impliedGenreEn, 'horror');
    });

    test('描述式查询（主角叫X）', () {
      final pq = parseQuery('背景在荒山中，主角叫拿破仑的恐怖电影');
      expect(pq.descriptive, isTrue);
      expect(pq.entities, ['拿破仑']);
      expect(pq.settingTerms, isNotEmpty);
      expect(pq.genreZh, '恐怖');
    });

    test('1990s 英文年代写法', () {
      final pq = parseQuery('僵尸 1990s');
      expect(pq.creatures, contains('丧尸')); // 僵尸是丧尸的语境词？不，需确认
      expect(pq.yearFrom, 1990);
    });
  });

  group('繁简转换', () {
    test('常见片名用字', () {
      expect(t2s('亞瑟府的沒落'), '亚瑟府的没落');
      expect(t2s('巨齒鯊'), '巨齿鲨');
      expect(t2s('大白鯊'), '大白鲨');
    });
  });

  group('聚合合并', () {
    test('按 imdb_id 强对齐去重', () {
      final a = Movie(title: 'Zombieland', imdbId: 'tt1153844', year: 2009,
          sources: ['justwatch']);
      final b = Movie(title: '丧尸乐园', originalTitle: 'Zombieland', imdbId: 'tt1153844',
          sources: ['tmdb']);
      final merged = Engine.mergeMovies([
        [a],
        [b],
      ]);
      expect(merged.length, 1);
      expect(merged.first.sources.toSet(), containsAll(['justwatch', 'tmdb']));
      expect(merged.first.title, '丧尸乐园'); // 中文优先
    });

    test('标题+年份模糊对齐（±1年）', () {
      final a = Movie(title: 'Jaws', year: 1975, sources: ['a']);
      final b = Movie(title: 'Jaws', year: 1976, sources: ['b']);
      final c = Movie(title: 'Jaws', year: 2000, sources: ['c']);
      final merged = Engine.mergeMovies([
        [a, c],
        [b],
      ]);
      expect(merged.length, 2);
    });
  });
}
