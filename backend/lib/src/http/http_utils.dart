import 'dart:convert';

import 'package:pontomax_core/pontomax_core.dart';
import 'package:shelf/shelf.dart';

/// Erro de API convertido em resposta JSON `{error: {code, message}}`.
class ApiError implements Exception {
  final int status;
  final String code;
  final String message;
  final Map<String, Object?>? details;

  const ApiError(this.status, this.code, this.message, [this.details]);

  const ApiError.badRequest(String message, [Map<String, Object?>? details])
      : this(400, 'bad_request', message, details);
  const ApiError.unauthorized([String message = 'Não autenticado'])
      : this(401, 'unauthorized', message);
  const ApiError.forbidden([String message = 'Acesso negado'])
      : this(403, 'forbidden', message);
  const ApiError.notFound([String message = 'Não encontrado'])
      : this(404, 'not_found', message);
  const ApiError.conflict(String message) : this(409, 'conflict', message);
  const ApiError.unprocessable(String code, String message)
      : this(422, code, message);

  Map<String, Object?> toJson() => {
        'error': {'code': code, 'message': message, if (details != null) 'details': details},
      };

  @override
  String toString() => 'ApiError($status, $code, $message)';
}

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

Object? _encodable(Object? v) {
  if (v is DateTime) return v.toUtc().toIso8601String();
  if (v is LocalDate) return v.toString();
  return v;
}

String encodeJson(Object? data) =>
    jsonEncode(data, toEncodable: (o) => _encodable(o) ?? o.toString());

Response jsonResponse(Object? data, {int status = 200, Map<String, String>? headers}) =>
    Response(status, body: encodeJson(data), headers: {..._jsonHeaders, ...?headers});

Response created(Object? data) => jsonResponse(data, status: 201);

Response noContent() => Response(204);

Response fileResponse(
  List<int> bytes, {
  required String contentType,
  String? filename,
  bool inline = false,
}) =>
    Response.ok(bytes, headers: {
      'content-type': contentType,
      if (filename != null)
        'content-disposition':
            '${inline ? 'inline' : 'attachment'}; filename="${filename.replaceAll('"', '')}"',
    });

/// Lê o corpo como JSON (objeto).
Future<Map<String, dynamic>> readJson(Request req) async {
  final body = await req.readAsString();
  if (body.trim().isEmpty) return {};
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    // continua abaixo
  }
  throw const ApiError.badRequest('JSON inválido');
}

/// Acesso tipado e validado aos campos de um JSON de entrada.
extension JsonFields on Map<String, dynamic> {
  String str(String key, {String? label}) {
    final v = this[key];
    if (v == null || v.toString().trim().isEmpty) {
      throw ApiError.badRequest('Campo obrigatório: ${label ?? key}', {'field': key});
    }
    return v.toString().trim();
  }

  String? optStr(String key) {
    final v = this[key];
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  int? optInt(String key) {
    final v = this[key];
    if (v == null || v == '') return null;
    if (v is num) return v.toInt();
    final parsed = int.tryParse(v.toString());
    if (parsed == null) throw ApiError.badRequest('Número inválido: $key', {'field': key});
    return parsed;
  }

  double? optDouble(String key) {
    final v = this[key];
    if (v == null || v == '') return null;
    if (v is num) return v.toDouble();
    final parsed = double.tryParse(v.toString());
    if (parsed == null) throw ApiError.badRequest('Número inválido: $key', {'field': key});
    return parsed;
  }

  bool? optBool(String key) {
    final v = this[key];
    if (v == null) return null;
    if (v is bool) return v;
    return v.toString() == 'true';
  }

  LocalDate date(String key) {
    final v = optDate(key);
    if (v == null) throw ApiError.badRequest('Data obrigatória: $key', {'field': key});
    return v;
  }

  LocalDate? optDate(String key) {
    final v = this[key];
    if (v == null || v.toString().isEmpty) return null;
    final d = LocalDate.tryParse(v.toString());
    if (d == null) throw ApiError.badRequest('Data inválida: $key', {'field': key});
    return d;
  }

  List<String> strList(String key) {
    final v = this[key];
    if (v == null) return const [];
    if (v is! List) throw ApiError.badRequest('Lista inválida: $key', {'field': key});
    return [for (final e in v) e.toString()];
  }

  Map<String, dynamic> obj(String key) {
    final v = this[key];
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return v.cast<String, dynamic>();
    return {};
  }
}

/// Parâmetros de query.
extension QueryParams on Request {
  String? q(String key) {
    final v = url.queryParameters[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  LocalDate? qDate(String key) {
    final v = q(key);
    if (v == null) return null;
    final d = LocalDate.tryParse(v);
    if (d == null) throw ApiError.badRequest('Data inválida: $key');
    return d;
  }

  int qInt(String key, int fallback) => int.tryParse(q(key) ?? '') ?? fallback;

  String? get clientIp =>
      headers['x-forwarded-for']?.split(',').first.trim() ??
      headers['x-real-ip'] ??
      (context['shelf.io.connection_info'] as dynamic)?.remoteAddress?.address as String?;
}

/// Valida UUID para evitar erros de cast no banco.
String requireUuid(String? value, [String field = 'id']) {
  if (value == null ||
      !RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
          .hasMatch(value)) {
    throw ApiError.badRequest('Identificador inválido: $field');
  }
  return value.toLowerCase();
}

String? optUuid(String? value, [String field = 'id']) =>
    (value == null || value.isEmpty) ? null : requireUuid(value, field);
