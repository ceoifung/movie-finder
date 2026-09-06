// 共享 HTTP 客户端：浏览器头 + 每主机节流（纯 Dart）
import 'dart:async';

import 'package:http/http.dart' as http;

const kBrowserUa =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

final http.Client sharedClient = http.Client();

const _minInterval = Duration(milliseconds: 400); // 个人使用低频场景，节流从宽以提速
final Map<String, DateTime> _hostLast = {};
final Map<String, Future<void>> _hostChain = {}; // 每主机的排队链尾

/// 同主机的请求串行化 + 最小间隔（链式排队：后来者等前一个完成）
Future<void> throttleHost(String host) {
  final prev = _hostChain[host];
  final completer = Completer<void>();
  _hostChain[host] = completer.future;
  return () async {
    try {
      if (prev != null) await prev;
      final last = _hostLast[host];
      if (last != null) {
        final elapsed = DateTime.now().difference(last);
        if (elapsed < _minInterval) {
          await Future.delayed(_minInterval - elapsed);
        }
      }
      _hostLast[host] = DateTime.now();
    } finally {
      completer.complete();
    }
  }();
}

/// 带超时的 GET/POST（引擎内所有网络请求统一走这里，杜绝悬挂）
Future<http.Response> httpGet(Uri uri,
    {Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 6)}) {
  return http.get(uri, headers: headers).timeout(timeout);
}

Future<http.Response> httpPost(Uri uri,
    {Map<String, String>? headers, Object? body,
    Duration timeout = const Duration(seconds: 6)}) {
  return http.post(uri, headers: headers, body: body).timeout(timeout);
}

Map<String, String> browserHeaders({String? acceptLanguage}) => {
      'User-Agent': kBrowserUa,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': acceptLanguage ?? 'zh-CN,zh;q=0.9,en;q=0.8',
    };

/// 简单异步信号量（引擎多处复用）
class Semaphore {
  int _count;
  final _waiters = <Completer<void>>[];
  Semaphore(this._count);

  Future<void> acquire() {
    if (_count > 0) {
      _count--;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _count++;
    }
  }
}
