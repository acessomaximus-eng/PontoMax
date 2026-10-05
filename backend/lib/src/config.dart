import 'dart:io';

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
    final secret = opt('JWT_SECRET');
    if (secret == null && opt('PONTOMAX_ENV') == 'production') {
      throw StateError('JWT_SECRET é obrigatório em produção');
    }
    return Config(
      port: int.tryParse(opt('PORT') ?? '') ?? 8080,
      databaseUrl: opt('DATABASE_URL') ??
          'postgres://pontomax:pontomax@localhost:5432/pontomax',
      jwtSecret: secret ?? 'dev-secret-change-me',
      storageDir: opt('STORAGE_DIR') ?? 'storage',
      webDir: opt('WEB_DIR'),
      siteDir: opt('SITE_DIR'),
      publicUrl: opt('PUBLIC_URL') ?? 'http://localhost:8080',
      corsOrigins: (opt('CORS_ORIGINS') ?? '*').split(',').map((s) => s.trim()).toList(),
      passwordIterations: int.tryParse(opt('PASSWORD_ITERATIONS') ?? '') ?? 120000,
      inpiNumber: opt('REP_INPI_NUMBER') ?? '00000000000000000',
      developerDocument: opt('REP_DEVELOPER_CNPJ') ?? '00000000000000',
      smtpHost: opt('SMTP_HOST'),
      smtpPort: int.tryParse(opt('SMTP_PORT') ?? '') ?? 587,
      smtpUser: opt('SMTP_USER'),
      smtpPassword: opt('SMTP_PASSWORD'),
      mailFrom: opt('MAIL_FROM') ?? 'PontoMax <nao-responda@pontomax.app>',
      seedDemo: opt('SEED_DEMO') == 'true',
    );
  }
}
