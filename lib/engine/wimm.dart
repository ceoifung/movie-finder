// WhatIsMyMovie (Valossa AI) 语义搜索通道（描述式查询，网页免 key，纯 Dart）
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;

import 'http.dart';
import 'justwatch.dart';
import 'models.dart';
import 'taxonomy.dart';
import 'translate.dart';

final _titleYearRe = RegExp(r'^(.{2,80}?)\s*[\(（](\d{4})[\)）]\s*$');

class WimmAdapter {
  final status = SourceStatus('whatismymovie', 'scrape');
  final JustWatchAdapter resolver;

  WimmAdapter(this.resolver);

  /// 返回 null 表示跳过（非描述式查询）；抛错表示失败。
  Future<List<Movie>?> search(ParsedQuery pq, String country) async {
    if (!pq.descriptive && pq.raw.isEmpty) return null;

    var text = pq.raw;
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(text)) {
      final t = await translateZhTo(text, 'en');
      if (t.isNotEmpty) text = t;
    }

    final sw = Stopwatch()..start();
    final r = await throttleHost('whatismymovie.com').then((_) => httpGet(
          Uri.https('whatismymovie.com', '/results', {'text': text}),
          headers: browserHeaders(),
        ));
    if (r.statusCode != 200) {
      status.recordFail('HTTP ${r.statusCode}');
      throw Exception('wimm HTTP ${r.statusCode}');
    }

    final titles = <(String, int?)>[];
    final seen = <String>{};
    final soup = html_parser.parse(utf8.decode(r.bodyBytes));
    for (final el in soup.querySelectorAll('.panel-title')) {
      final t = el.text.trim();
      if (t.isEmpty || seen.contains(t.toLowerCase())) continue;
      seen.add(t.toLowerCase());
      final m = _titleYearRe.firstMatch(t);
      if (m != null) {
        titles.add((m.group(1)!.trim(), int.parse(m.group(2)!)));
      } else if (t.length >= 2 && t.length <= 80 && !t.toLowerCase().contains('more like')) {
        titles.add((t, null));
      }
      if (titles.length >= 20) break;
    }
    if (titles.isEmpty) {
      status.recordFail('no titles parsed');
      throw Exception('wimm no results');
    }

    // 回链解析：语义片名 -> JustWatch 完整条目（海报/评分/观看地址）
    final sem = Semaphore(4);
    final got = await Future.wait(titles.take(10).map((t) async {
      await sem.acquire();
      try {
        final ms = await resolver.resolveTitle(t.$1, country, pq);
        for (final m in ms) {
          if (t.$2 != null && m.year != null && (m.year! - t.$2!).abs() > 1) continue;
          return m;
        }
        return null;
      } finally {
        sem.release();
      }
    }));
    status.recordOk(sw.elapsedMilliseconds * 1.0);
    return [
      for (final m in got)
        if (m != null && m.title.isNotEmpty) (m..sources = ['whatismymovie'])
    ];
  }
}
