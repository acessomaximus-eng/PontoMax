import 'dart:io';
import 'dart:math';

/// Configuração via variáveis de ambiente.
class Config {
  final int port;
  final String databaseUrl;
  final String jwtSecret;
  final String storageDir;
  final String? webDir;
  final String? siteDir;
  final String publicUrl;
  final List<String> corsOrigins;
  final int passwordIterations;
  final Duration accessTokenTtl;
  final Duration refreshTokenTtl;
  final String inpiNumber;
  final String developerDocument;
  /// Certificado de assinatura do AFD/AEJ/comprovante: arquivo .pfx/.p12 (A1)
  /// ou PEM (certificado + chave). Sem ele, usa um autoassinado.
  final String? signingCertPath;
  final String? signingCertBase64;
  final String signingCertPassword;
  final String? smtpHost;
  final int smtpPort;
  final String? smtpUser;
  final String? smtpPassword;
  final String mailFrom;
  final bool seedDemo;

  const Config({
    this.port = 8080,
    this.databaseUrl = 'postgres://pontomax:pontomax@localhost:5432/pontomax',
    this.jwtSecret = 'dev-secret-change-me',
    this.storageDir = 'storage',
    this.webDir,
    this.siteDir,
    this.publicUrl = 'http://localhost:8080',
    this.corsOrigins = const ['*'],
    this.passwordIterations = 120000,
    this.accessTokenTtl = const Duration(hours: 2),
    this.refreshTokenTtl = const Duration(days: 30),
    this.inpiNumber = '00000000000000000',
    this.developerDocument = '00000000000000',
    this.signingCertPath,
    this.signingCertBase64,
    this.signingCertPassword = '',
    this.smtpHost,
    this.smtpPort = 587,
    this.smtpUser,
    this.smtpPassword,
    this.mailFrom = 'PontoMax <nao-responda@pontomax.app>',
    this.seedDemo = false,
  });

  factory Config.fromEnv([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    String? opt(String k) => (e[k]?.trim().isEmpty ?? true) ? null : e[k]!.trim();
    final storageDir = opt('STORAGE_DIR') ?? 'storage';
    final secret = opt('JWT_SECRET') ?? _persistedSecret(storageDir);
    return Config(
      port: int.tryParse(opt('PORT') ?? '') ?? 8080,
      databaseUrl: opt('DATABASE_URL') ??
          'postgres://pontomax:pontomax@localhost:5432/pontomax',
      jwtSecret: secret,
      storageDir: storageDir,
      webDir: opt('WEB_DIR'),
      siteDir: opt('SITE_DIR'),
      publicUrl: opt('PUBLIC_URL') ?? 'http://localhost:8080',
      corsOrigins: (opt('CORS_ORIGINS') ?? '*').split(',').map((s) => s.trim()).toList(),
      passwordIterations: int.tryParse(opt('PASSWORD_ITERATIONS') ?? '') ?? 120000,
      inpiNumber: opt('REP_INPI_NUMBER') ?? '00000000000000000',
      developerDocument: opt('REP_DEVELOPER_CNPJ') ?? '00000000000000',
      signingCertPath: opt('SIGNING_CERT_PATH'),
      signingCertBase64: opt('SIGNING_CERT_BASE64'),
      signingCertPassword: opt('SIGNING_CERT_PASSWORD') ?? '',
      smtpHost: opt('SMTP_HOST'),
      smtpPort: int.tryParse(opt('SMTP_PORT') ?? '') ?? 587,
      smtpUser: opt('SMTP_USER'),
      smtpPassword: opt('SMTP_PASSWORD'),
      mailFrom: opt('MAIL_FROM') ?? 'PontoMax <nao-responda@pontomax.app>',
      seedDemo: opt('SEED_DEMO') == 'true',
    );
  }

  /// Sem `JWT_SECRET`, gera um segredo aleatório e o guarda em
  /// `STORAGE_DIR/.jwt_secret` (persistente no volume do Docker), para que o
  /// sistema rode sem configuração e os logins sobrevivam a reinícios.
  static String _persistedSecret(String storageDir) {
    final file = File('$storageDir/.jwt_secret');
    if (file.existsSync()) {
      final saved = file.readAsStringSync().trim();
      if (saved.length >= 32) return saved;
    }
    final rnd = Random.secure();
    final secret = List.generate(32, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(secret);
    if (!Platform.isWindows) Process.runSync('chmod', ['600', file.path]);
    stderr.writeln('JWT_SECRET não definido: segredo aleatório gerado em ${file.path}');
    return secret;
  }
}
