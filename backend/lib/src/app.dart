import 'auth/crypto_utils.dart';
import 'auth/session.dart';
import 'config.dart';
import 'db/database.dart';
import 'services/audit_service.dart';
import 'services/event_bus.dart';
import 'services/mailer.dart';
import 'services/notification_service.dart';
import 'services/punch_service.dart';
import 'services/report_service.dart';
import 'services/storage_service.dart';
import 'services/timesheet_service.dart';

/// Contêiner de dependências da aplicação.
class App {
  final Config config;
  final Database db;
  final DateTime Function() _clock;

  late final PasswordHasher passwords = PasswordHasher(iterations: config.passwordIterations);
  late final SessionService sessions = SessionService(this);
  late final StorageService storage = StorageService(this);
  late final AuditService audit = AuditService(this);
  late final EventBus events = EventBus();
  late final NotificationService notifications = NotificationService(this);
  late final Mailer mailer = Mailer(config);
  late final PunchService punches = PunchService(this);
  late final TimesheetService timesheets = TimesheetService(this);
  late final ReportService reports = ReportService(this);

  App(this.config, this.db, {DateTime Function()? clock})
      : _clock = clock ?? (() => DateTime.now().toUtc());

  /// Instante atual em UTC (injetável nos testes).
  DateTime now() => _clock().toUtc();
}
