import 'dart:convert';
import 'dart:io';

import 'package:pontomax_backend/server.dart';
import 'package:pontomax_backend/src/signing/cms.dart';
import 'package:pontomax_backend/src/signing/der.dart';
import 'package:shelf/shelf.dart';

/// Relógio controlável para os testes.
class TestClock {
  DateTime value = DateTime.utc(2026, 10, 5, 11, 0); // 08:00 em Brasília (segunda)
  DateTime call() => value;
  void set(DateTime utc) => value = utc.toUtc();

  /// Define o relógio por horário de Brasília.
  void brt(int y, int m, int d, int h, [int min = 0]) => value = DateTime.utc(y, m, d, h + 3, min);
  void advance(Duration d) => value = value.add(d);
}

class ApiResponse {
  final int status;
  final dynamic body;
  final List<int> bytes;
  final Map<String, String> headers;
  ApiResponse(this.status, this.body, this.bytes, this.headers);

  Map<String, dynamic> get json => body as Map<String, dynamic>;
  List<dynamic> get list => body as List<dynamic>;

  @override
  String toString() => 'ApiResponse($status, $body)';
}

class TestApi {
  final App app;
  final Handler handler;
  final TestClock clock;
  final Directory storage;

  TestApi._(this.app, this.handler, this.clock, this.storage);

  static Future<TestApi> create() async {
    final storage = await Directory.systemTemp.createTemp('pontomax_test');
    final config = Config(
      databaseUrl: Platform.environment['TEST_DATABASE_URL'] ??
          'postgres://pontomax:pontomax@localhost:5432/pontomax_test',
      passwordIterations: 1000,
      storageDir: storage.path,
      jwtSecret: 'test-secret',
    );
    final db = Database.connect(config.databaseUrl, maxConnections: 4);
    await db.resetForTests();
    final clock = TestClock();
    final app = App(config, db, clock: clock.call);
    return TestApi._(app, buildHandler(app), clock, storage);
  }

  Future<void> close() async {
    await app.db.close();
    await storage.delete(recursive: true);
  }

  Future<ApiResponse> call(
    String method,
    String path, {
    Object? body,
    String? token,
    String? company,
    String? device,
    Map<String, String> headers = const {},
    List<int>? rawBody,
  }) async {
    final req = Request(
      method,
      Uri.parse('http://localhost/api/v1$path'),
      body: rawBody ?? (body == null ? null : jsonEncode(body)),
      headers: {
        if (body != null) 'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
        if (device != null) 'authorization': 'Device $device',
        if (company != null) 'x-company-id': company,
        ...headers,
      },
    );
    final res = await handler(req);
    final bytes = await res.read().expand((c) => c).toList();
    dynamic decoded;
    final type = res.headers['content-type'] ?? '';
    if (type.contains('json')) {
      decoded = bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
    } else {
      decoded = null;
    }
    return ApiResponse(res.statusCode, decoded, bytes, res.headers);
  }

  Future<ApiResponse> get(String path, {String? token, String? company, String? device}) =>
      call('GET', path, token: token, company: company, device: device);
  Future<ApiResponse> post(String path, Object? body, {String? token, String? company, String? device}) =>
      call('POST', path, body: body ?? {}, token: token, company: company, device: device);
  Future<ApiResponse> put(String path, Object? body, {String? token, String? company}) =>
      call('PUT', path, body: body ?? {}, token: token, company: company);
  Future<ApiResponse> delete(String path, {String? token, String? company}) =>
      call('DELETE', path, token: token, company: company);

  /// Registra uma empresa e devolve (token, companyId, memberId).
  Future<(String, String, String)> register({
    String email = 'dono@empresa.com',
    String company = 'Empresa Teste',
    String cpf = '52998224725',
  }) async {
    final r = await post('/auth/register', {
      'company_name': company,
      'document': '11222333000181',
      'name': 'Dona da Empresa',
      'email': email,
      'password': 'senha1234',
      'cpf': cpf,
    });
    if (r.status != 201) throw StateError('register falhou: $r');
    final token = r.json['access_token'] as String;
    final membership = (r.json['memberships'] as List).first as Map;
    return (token, membership['company_id'] as String, membership['member_id'] as String);
  }

  Future<String> login(String email, [String password = 'senha1234']) async {
    final r = await post('/auth/login', {'email': email, 'password': password});
    if (r.status != 200) throw StateError('login falhou: $r');
    return r.json['access_token'] as String;
  }
}

/// Confere a assinatura PAdES de um PDF: ByteRange cobre o arquivo todo
/// (exceto /Contents) e o CMS confere com esses bytes.
bool pdfSignatureValid(List<int> pdf) {
  final text = latin1.decode(pdf);
  final m = RegExp(r'/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]').firstMatch(text);
  if (m == null) return false;
  final r = [for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
  if (r[0] != 0 || r[2] + r[3] != pdf.length) return false;
  final hex = text.substring(r[1] + 1, r[2] - 1);
  final padded = [for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
  final cms = DerNode.parse(padded).raw; // descarta o preenchimento com zeros
  final signed = [...pdf.sublist(0, r[1]), ...pdf.sublist(r[2])];
  return CmsVerifier.verifyDetached(cms, signed).valid;
}
