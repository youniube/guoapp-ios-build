import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class PythonWebResolver {
  static final instance = PythonWebResolver();
  Future<String>? _starting;
  String _path = '';
  int _active = 0;

  Future<String> start() => _starting ??= _start();

  Future<String> _start() async {
    final random = Random.secure();
    final token = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _path = '/resolve/$token';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      unawaited(_serve(request));
    });
    return 'http://127.0.0.1:${server.port}$_path';
  }

  Future<void> _serve(HttpRequest request) async {
    if (request.uri.path != _path || request.method != 'POST' || _active >= 2) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    _active++;
    try {
      final bytes = <int>[];
      await for (final chunk in request) {
        if (bytes.length + chunk.length > 128 * 1024) {
          throw const FormatException('参数过长');
        }
        bytes.addAll(chunk);
      }
      final input = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final original = Uri.tryParse(input['origin'] as String);
      final origin =
          original != null &&
              {'http', 'https'}.contains(original.scheme) &&
              original.host.isNotEmpty
          ? original.origin
          : '';
      final headers = {
        for (final entry in (input['headers'] as Map? ?? const {}).entries)
          '${entry.key}': '${entry.value}',
      };
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      Map<String, dynamic>? result;
      for (final page in (input['pages'] as List).whereType<String>().toSet()) {
        final uri = Uri.tryParse(page);
        if (uri == null ||
            !{'http', 'https'}.contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          continue;
        }
        final remaining = deadline.difference(DateTime.now());
        if (remaining.isNegative) break;
        final scoped = {
          for (final entry in headers.entries)
            if (uri.origin == origin ||
                {
                  'user-agent',
                  'referer',
                  'accept',
                }.contains(entry.key.toLowerCase()))
              entry.key: entry.value,
        };
        result = await _sniff(
          uri,
          scoped,
          remaining < const Duration(seconds: 6)
              ? remaining
              : const Duration(seconds: 6),
        );
        if (result != null) break;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result ?? {'error': '网页未返回可播放媒体地址'}));
    } catch (_) {
      request.response.statusCode = HttpStatus.badGateway;
      request.response.write('{"error":"网页解析失败"}');
    } finally {
      _active--;
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>?> _sniff(
    Uri page,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    final found = Completer<Map<String, dynamic>?>();
    Future<void> accept(
      String address, [
      Map<String, String> captured = const {},
      String mime = '',
    ]) async {
      final uri = Uri.tryParse(address);
      if (found.isCompleted ||
          uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty) {
        return;
      }
      final media =
          RegExp(
            r'\.(m3u8|mp4|m4v|mkv|webm|flv|mpd)(?:$|[?])',
            caseSensitive: false,
          ).hasMatch(address) ||
          mime.toLowerCase().contains('mpegurl') ||
          mime.toLowerCase().startsWith('video/');
      if (!media) return;
      final resultHeaders = Map<String, String>.from(captured);
      resultHeaders.putIfAbsent('Referer', () => page.toString());
      try {
        final cookies = await CookieManager.instance().getCookies(
          url: WebUri(address),
        );
        if (cookies.isNotEmpty) {
          resultHeaders['Cookie'] = cookies
              .map((cookie) => '${cookie.name}=${cookie.value}')
              .join('; ');
        }
      } catch (_) {}
      if (!found.isCompleted) {
        found.complete({'url': address, 'headers': resultHeaders});
      }
    }

    final view = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(page.toString()),
        headers: headers,
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        useOnLoadResource: true,
        useShouldInterceptRequest: true,
        useOnNavigationResponse: true,
        userAgent: headers.entries
            .where((entry) => entry.key.toLowerCase() == 'user-agent')
            .firstOrNull
            ?.value,
      ),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: _captureScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
      ]),
      onWebViewCreated: (controller) {
        controller.addJavaScriptHandler(
          handlerName: 'guoMedia',
          callback: (arguments) {
            if (arguments.isEmpty || arguments.first is! Map) return null;
            final item = Map<String, dynamic>.from(arguments.first as Map);
            final captured = {
              for (final entry in (item['headers'] as Map? ?? const {}).entries)
                '${entry.key}': '${entry.value}',
            };
            unawaited(
              accept('${item['url'] ?? ''}', captured, '${item['mime'] ?? ''}'),
            );
            return null;
          },
        );
      },
      onLoadResource: (controller, resource) {
        unawaited(accept(resource.url?.toString() ?? ''));
      },
      shouldInterceptRequest: (controller, request) async {
        unawaited(accept(request.url.toString(), request.headers ?? {}));
        return null;
      },
      onNavigationResponse: (controller, navigation) async {
        final response = navigation.response;
        await accept(
          response?.url?.toString() ?? '',
          const {},
          response?.mimeType ?? '',
        );
        return found.isCompleted
            ? NavigationResponseAction.CANCEL
            : NavigationResponseAction.ALLOW;
      },
      onLoadStop: (controller, url) async {
        await controller.evaluateJavascript(source: _captureScript);
      },
    );
    try {
      await view.run().timeout(timeout);
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      return await found.future.timeout(remaining, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      if (!found.isCompleted) found.complete(null);
      try {
        await view.dispose();
      } catch (_) {}
    }
  }

  static const _captureScript = r'''
(() => {
  if (window.__guoMediaInstalled) return;
  window.__guoMediaInstalled = true;
  const queue = [];
  const media = u => /\.(m3u8|mp4|m4v|mkv|webm|flv|mpd)(?:$|[?])/i.test(u);
  const emit = (url, headers = {}, mime = '') => {
    try {
      url = new URL(url, location.href).href;
      if (!/^https?:/.test(url) || (!media(url) && !/mpegurl|^video\//i.test(mime))) return;
      queue.push({url, headers, mime});
    } catch (_) {}
  };
  const inspect = (value, depth = 0) => {
    if (depth > 5 || value == null) return;
    if (typeof value === 'string') { emit(value); return; }
    if (Array.isArray(value)) { value.slice(0, 100).forEach(v => inspect(v, depth + 1)); return; }
    if (typeof value === 'object') Object.values(value).slice(0, 100).forEach(v => inspect(v, depth + 1));
  };
  const originalFetch = window.fetch;
  window.fetch = async function(input, options) {
    const response = await originalFetch.apply(this, arguments);
    const headers = Object.fromEntries(new Headers(options?.headers || (input instanceof Request ? input.headers : {})).entries());
    const mime = response.headers.get('content-type') || '';
    emit(response.url, headers, mime);
    if (/json/i.test(mime)) response.clone().json().then(value => inspect(value)).catch(() => {});
    return response;
  };
  const open = XMLHttpRequest.prototype.open;
  const setHeader = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.open = function(method, url) {
    this.__guoHeaders = {};
    this.addEventListener('load', () => {
      emit(this.responseURL || url, this.__guoHeaders, this.getResponseHeader('content-type') || '');
      try { if (this.responseType === 'json') inspect(this.response); else if (!this.responseType || this.responseType === 'text') inspect(JSON.parse(this.responseText)); } catch (_) {}
    });
    return open.apply(this, arguments);
  };
  XMLHttpRequest.prototype.setRequestHeader = function(name, value) { this.__guoHeaders[name] = value; return setHeader.apply(this, arguments); };
  const scan = () => {
    document.querySelectorAll('video,audio,source').forEach(node => emit(node.currentSrc || node.src, {}, node.type || ''));
    performance.getEntriesByType('resource').forEach(resource => emit(resource.name));
    if (window.flutter_inappwebview?.callHandler) while (queue.length) window.flutter_inappwebview.callHandler('guoMedia', queue.shift());
  };
  setInterval(scan, 250);
  scan();
})();
''';
}
