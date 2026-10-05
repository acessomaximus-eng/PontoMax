import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// Erro retornado pela API (ou de rede).
class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  const ApiException(this.status, this.code, this.message);

  /// Falha de conectividade (sem resposta do servidor).
  bool get isNetwork => status == 0;

  @override
  String toString() => message;
}

/// Cliente HTTP da API do PontoMax com renovação automática do token.
class ApiClient {
  final http.Client _http;
  String? accessToken;
  String? refreshToken;
  String? companyId;
  String? deviceToken;

  /// Chamado quando os tokens são renovados (para persistir).
  void Function(String access, String refresh)? onTokens;

  /// Chamado quando a sessão expira definitivamente.
  void Function()? onSessionExpired;

  Future<bool>? _refreshing;

  ApiClient({http.Client? client}) : _http = client ?? http.Client();

  String get baseUrl => AppConfig.apiUrl;

  Uri uri(String path, [Map<String, Object?>? query]) {
    final q = <String, String>{
      for (final e in (query ?? const {}).entries)
        if (e.value != null && e.value.toString().isNotEmpty)
          e.key: e.value.toString(),
    };
    return Uri.parse('$baseUrl$path')
        .replace(queryParameters: q.isEmpty ? null : q);
  }

  Map<String, String> _headers({bool json = true, bool device = false}) => {
    if (json) 'content-type': 'application/json',
    'accept': 'application/json',
    if (device && deviceToken != null) 'authorization': 'Device $deviceToken',
    if (!device && accessToken != null) 'authorization': 'Bearer $accessToken',
    if (!device && companyId != null) 'x-company-id': companyId!,
  };

  Future<http.Response> _send(
    String method,
    String path, {
    Object? body,
    Map<String, Object?>? query,
    bool device = false,
    bool retry = true,
    Map<String, String>? extraHeaders,
    List<int>? rawBody,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final req = http.Request(method, uri(path, query));
    req.headers.addAll(_headers(json: rawBody == null, device: device));
    if (extraHeaders != null) req.headers.addAll(extraHeaders);
    if (rawBody != null) {
      req.bodyBytes = rawBody;
    } else if (body != null) {
      req.body = jsonEncode(body);
    }
    http.Response res;
    try {
      final streamed = await _http.send(req).timeout(timeout);
      res = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw const ApiException(
        0,
        'timeout',
        'O servidor demorou para responder. Verifique sua conexão.',
      );
    } on http.ClientException catch (e) {
      debugPrint('Falha de rede: $e');
      throw const ApiException(0, 'network', 'Sem conexão com o servidor.');
    } catch (e) {
      // SocketException e afins (dart:io) não estão disponíveis na web.
      debugPrint('Falha de rede: $e');
      throw const ApiException(0, 'network', 'Sem conexão com o servidor.');
    }

    if (res.statusCode == 401 && !device && retry && refreshToken != null) {
      final err = _decodeError(res);
      if (err.code == 'token_expired' || err.code == 'unauthorized') {
        if (await _refresh()) {
          return _send(
            method,
            path,
            body: body,
            query: query,
            retry: false,
            extraHeaders: extraHeaders,
            rawBody: rawBody,
            timeout: timeout,
          );
        }
        onSessionExpired?.call();
      }
    }
    if (res.statusCode >= 400) throw _decodeError(res);
    return res;
  }

  ApiException _decodeError(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final e = j['error'] as Map<String, dynamic>;
      return ApiException(
        res.statusCode,
        e['code'] as String? ?? 'error',
        e['message'] as String? ?? 'Erro',
      );
    } catch (_) {
      return ApiException(res.statusCode, 'error', 'Erro ${res.statusCode}');
    }
  }

  Future<bool> _refresh() {
    return _refreshing ??= () async {
      try {
        final res = await _http.post(
          uri('/auth/refresh'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'refresh_token': refreshToken}),
        );
        if (res.statusCode != 200) return false;
        final j =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        accessToken = j['access_token'] as String;
        refreshToken = j['refresh_token'] as String;
        onTokens?.call(accessToken!, refreshToken!);
        return true;
      } catch (_) {
        return false;
      } finally {
        _refreshing = null;
      }
    }();
  }

  dynamic _decode(http.Response res) {
    if (res.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<dynamic> get(
    String path, {
    Map<String, Object?>? query,
    bool device = false,
    Duration? timeout,
  }) async => _decode(
    await _send(
      'GET',
      path,
      query: query,
      device: device,
      timeout: timeout ?? const Duration(seconds: 30),
    ),
  );

  Future<dynamic> post(
    String path, [
    Object? body,
    bool device = false,
  ]) async => _decode(
    await _send('POST', path, body: body ?? const {}, device: device),
  );

  Future<dynamic> put(String path, [Object? body]) async =>
      _decode(await _send('PUT', path, body: body ?? const {}));

  Future<dynamic> delete(String path) async =>
      _decode(await _send('DELETE', path));

  Future<Map<String, dynamic>> getMap(
    String path, {
    Map<String, Object?>? query,
  }) async => (await get(path, query: query) as Map).cast<String, dynamic>();

  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, Object?>? query,
  }) async => [
    for (final e in await get(path, query: query) as List)
      (e as Map).cast<String, dynamic>(),
  ];

  /// Baixa um arquivo autenticado (PDF, CSV, AFD...).
  Future<(Uint8List, String?)> download(
    String path, {
    Map<String, Object?>? query,
  }) async {
    final res = await _send(
      'GET',
      path,
      query: query,
      timeout: const Duration(minutes: 3),
    );
    final disposition = res.headers['content-disposition'];
    final name = disposition == null
        ? null
        : RegExp(r'filename="([^"]+)"').firstMatch(disposition)?.group(1);
    return (res.bodyBytes, name);
  }

  /// Envia um arquivo (bytes crus) e retorna `{id, url}`.
  Future<Map<String, dynamic>> upload(
    Uint8List bytes,
    String contentType,
    String filename, {
    bool device = false,
  }) async {
    final res = await _send(
      'POST',
      device ? '/kiosk/upload' : '/files',
      rawBody: bytes,
      device: device,
      extraHeaders: {
        'content-type': contentType,
        'x-filename': Uri.encodeComponent(filename),
      },
      timeout: const Duration(minutes: 2),
    );
    return (_decode(res) as Map).cast<String, dynamic>();
  }
}
