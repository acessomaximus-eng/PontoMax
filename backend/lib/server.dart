import 'dart:io';

import 'package:logging/logging.dart';
import 'package:postgres/postgres.dart' show ServerException;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'src/app.dart';
import 'src/http/http_utils.dart';
import 'src/routes/auth_routes.dart';
import 'src/routes/company_routes.dart';
import 'src/routes/integration_routes.dart';
import 'src/routes/kiosk_routes.dart';
import 'src/routes/member_routes.dart';
import 'src/routes/punch_routes.dart';
import 'src/routes/report_routes.dart';
import 'src/routes/request_routes.dart';
import 'src/routes/social_routes.dart';

export 'src/app.dart';
export 'src/config.dart';
export 'src/db/database.dart';

final _log = Logger('http');

const apiVersion = '0.1.0';

/// Monta o handler HTTP completo (API + app web + site).
Handler buildHandler(App app) {
  final api = Cascade()
      .add((Router()
        ..get('/health', (Request r) async {
          await app.db.query('SELECT 1');
          return jsonResponse({'status': 'ok', 'version': apiVersion, 'time': app.now().toIso8601String()});
        })).call)
      .add(AuthRoutes(app).router.call)
      .add(CompanyRoutes(app).router.call)
      .add(MemberRoutes(app).router.call)
      .add(PunchRoutes(app).router.call)
      .add(RequestRoutes(app).router.call)
      .add(ReportRoutes(app).router.call)
      .add(SocialRoutes(app).router.call)
      .add(KioskRoutes(app).router.call)
      .add(IntegrationRoutes(app).router.call)
      .add((Request r) => throw const ApiError(404, 'route_not_found', 'Rota não encontrada'))
      .handler;

  final root = Router()..mount('/api/v1/', api);

  var cascade = Cascade().add(root.call);
  final webDir = app.config.webDir;
  if (webDir != null && Directory(webDir).existsSync()) {
    final web = createStaticHandler(webDir, defaultDocument: 'index.html');
    cascade = cascade.add((Request r) {
      if (r.url.path == 'app') return Response.found('/app/');
      if (!r.url.path.startsWith('app/')) return Response.notFound('');
      final inner = r.change(path: 'app');
      return web(inner);
    });
  }
  final siteDir = app.config.siteDir;
  if (siteDir != null && Directory(siteDir).existsSync()) {
    cascade = cascade.add(createStaticHandler(siteDir, defaultDocument: 'index.html'));
  }

  return const Pipeline()
      .addMiddleware(_logRequests())
      .addMiddleware(_cors(app.config.corsOrigins))
      .addMiddleware(_securityHeaders())
      .addMiddleware(_errors())
      .addHandler(cascade.handler);
}

Middleware _errors() => (inner) => (req) async {
      try {
        return await inner(req);
      } on ApiError catch (e) {
        return jsonResponse(e.toJson(), status: e.status);
      } on ServerException catch (e, st) {
        if (e.code == '23505') {
          return jsonResponse(const ApiError.conflict('Registro duplicado').toJson(), status: 409);
        }
        if (e.code == '23503') {
          return jsonResponse(
              const ApiError(409, 'in_use', 'Registro relacionado não encontrado ou em uso').toJson(),
              status: 409);
        }
        if (e.code == '22P02' || e.code == '22007' || e.code == '22008') {
          return jsonResponse(const ApiError.badRequest('Valor inválido').toJson(), status: 400);
        }
        _log.severe('Erro de banco em ${req.method} ${req.requestedUri.path}', e, st);
        return jsonResponse(const ApiError(500, 'internal', 'Erro interno').toJson(), status: 500);
      } on FormatException catch (e) {
        return jsonResponse(ApiError.badRequest(e.message).toJson(), status: 400);
      } catch (e, st) {
        _log.severe('Erro em ${req.method} ${req.requestedUri.path}', e, st);
        return jsonResponse(const ApiError(500, 'internal', 'Erro interno').toJson(), status: 500);
      }
    };

Middleware _cors(List<String> origins) {
  const allowHeaders = 'Authorization, Content-Type, X-Company-Id, X-Filename, X-Api-Key';
  const allowMethods = 'GET, POST, PUT, PATCH, DELETE, OPTIONS';
  return (inner) => (req) async {
        final origin = req.headers['origin'];
        String? allowOrigin;
        if (origin != null) {
          if (origins.contains('*')) {
            allowOrigin = '*';
          } else if (origins.contains(origin)) {
            allowOrigin = origin;
          }
        }
        final headers = <String, String>{
          if (allowOrigin != null) 'access-control-allow-origin': allowOrigin,
          'access-control-allow-headers': allowHeaders,
          'access-control-allow-methods': allowMethods,
          'access-control-expose-headers': 'Content-Disposition',
          'access-control-max-age': '86400',
          if (allowOrigin != null && allowOrigin != '*') 'vary': 'Origin',
        };
        if (req.method == 'OPTIONS') return Response.ok('', headers: headers);
        final res = await inner(req);
        return res.change(headers: headers);
      };
}

Middleware _securityHeaders() => (inner) => (req) async {
      final res = await inner(req);
      return res.change(headers: {
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'strict-origin-when-cross-origin',
        'x-frame-options': 'SAMEORIGIN',
      });
    };

Middleware _logRequests() => (inner) => (req) async {
      final sw = Stopwatch()..start();
      final res = await inner(req);
      if (req.url.path.startsWith('api/')) {
        _log.info('${req.method} /${req.url.path} ${res.statusCode} ${sw.elapsedMilliseconds}ms');
      }
      return res;
    };
