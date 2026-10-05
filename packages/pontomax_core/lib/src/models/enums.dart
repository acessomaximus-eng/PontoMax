/// Enumerações compartilhadas entre backend e app.
///
/// Todas possuem um `code` estável (persistido no banco e trafegado na API)
/// e um `label` em português para exibição.
library;

T _byCode<T extends Enum>(
    List<T> values, String? code, T fallback, String Function(T) codeOf) {
  for (final v in values) {
    if (codeOf(v) == code) return v;
  }
  return fallback;
}

/// Papel do usuário dentro de uma empresa.
enum Role {
  owner('owner', 'Proprietário'),
  admin('admin', 'Administrador'),
  manager('manager', 'Gestor'),
  employee('employee', 'Colaborador');

  const Role(this.code, this.label);
  final String code;
  final String label;

  static Role fromCode(String? code) =>
      _byCode(values, code, Role.employee, (v) => v.code);

  /// Pode acessar o painel de gestão.
  bool get isManager => this != Role.employee;

  /// Pode alterar configurações da empresa e permissões.
  bool get isAdmin => this == Role.owner || this == Role.admin;
}

/// Coletor da marcação (campo "identificador do coletor" do AFD para REP-P).
enum PunchSource {
  mobile('mobile', '01', 'Aplicativo mobile'),
  browser('browser', '02', 'Navegador web'),
  desktop('desktop', '03', 'Aplicativo desktop'),
  device('device', '04', 'Dispositivo eletrônico (quiosque)'),
  other('other', '05', 'Outro');

  const PunchSource(this.code, this.afdCode, this.label);
  final String code;

  /// Código de 2 dígitos do AFD (registro tipo 7).
  final String afdCode;
  final String label;

  static PunchSource fromCode(String? code) =>
      _byCode(values, code, PunchSource.other, (v) => v.code);
}

/// Método de identificação usado no momento da marcação.
enum PunchMethod {
  app('app', 'Aplicativo'),
  qrCode('qr', 'QR Code'),
  pin('pin', 'PIN no quiosque'),
  badge('badge', 'Crachá'),
  face('face', 'Reconhecimento facial'),
  voice('voice', 'Comando de voz'),
  manual('manual', 'Inclusão manual');

  const PunchMethod(this.code, this.label);
  final String code;
  final String label;

  static PunchMethod fromCode(String? code) =>
      _byCode(values, code, PunchMethod.app, (v) => v.code);
}

/// Fonte da marcação no AEJ (Portaria 671, Anexo VI — campo `fonteMarc`).
enum PunchOrigin {
  original('O', 'Original (REP)'),
  included('I', 'Incluída pelo gestor'),
  preAssigned('P', 'Pré-assinalada'),
  exception('X', 'Ponto por exceção'),
  other('T', 'Outras fontes');

  const PunchOrigin(this.code, this.label);
  final String code;
  final String label;

  static PunchOrigin fromCode(String? code) =>
      _byCode(values, code, PunchOrigin.original, (v) => v.code);
}

/// Regime de compensação da escala.
enum CompensationRegime {
  /// Saldo positivo vira hora extra; negativo vira desconto.
  overtime('overtime', 'Horas extras'),

  /// Todo saldo (positivo ou negativo) vai para o banco de horas.
  hourBank('hour_bank', 'Banco de horas'),

  /// Banco de horas até o limite diário e o excedente como hora extra.
  hybrid('hybrid', 'Híbrido (banco + extras)');

  const CompensationRegime(this.code, this.label);
  final String code;
  final String label;

  static CompensationRegime fromCode(String? code) =>
      _byCode(values, code, CompensationRegime.overtime, (v) => v.code);
}

/// Tipo de escala.
enum ScheduleType {
  /// 7 modelos de dia (segunda a domingo).
  weekly('weekly', 'Semanal'),

  /// N modelos de dia que se repetem a partir de uma data âncora (12x36, 6x1...).
  cycle('cycle', 'Cíclica (12x36, 6x1, etc.)');

  const ScheduleType(this.code, this.label);
  final String code;
  final String label;

  static ScheduleType fromCode(String? code) =>
      _byCode(values, code, ScheduleType.weekly, (v) => v.code);
}

/// Tipo de solicitação feita pelo colaborador.
enum RequestType {
  forgotPunch('forgot_punch', 'Esquecimento de marcação'),
  adjustment('adjustment', 'Ajuste de marcação'),
  medicalCertificate('medical', 'Atestado médico'),
  allowance('allowance', 'Abono'),
  bankDayOff('bank_day_off', 'Folga (banco de horas)'),
  vacation('vacation', 'Férias');

  const RequestType(this.code, this.label);
  final String code;
  final String label;

  static RequestType fromCode(String? code) =>
      _byCode(values, code, RequestType.adjustment, (v) => v.code);

  /// Solicitações que geram ausência/abono ao serem aprovadas.
  bool get createsAbsence =>
      this == medicalCertificate ||
      this == allowance ||
      this == bankDayOff ||
      this == vacation;

  /// Solicitações que geram marcações incluídas ao serem aprovadas.
  bool get createsPunches => this == forgotPunch || this == adjustment;

  AbsenceType? get absenceType => switch (this) {
        medicalCertificate => AbsenceType.medical,
        allowance => AbsenceType.allowance,
        bankDayOff => AbsenceType.bankDayOff,
        vacation => AbsenceType.vacation,
        _ => null,
      };
}

enum RequestStatus {
  pending('pending', 'Pendente'),
  approved('approved', 'Aprovada'),
  rejected('rejected', 'Recusada'),
  cancelled('cancelled', 'Cancelada');

  const RequestStatus(this.code, this.label);
  final String code;
  final String label;

  static RequestStatus fromCode(String? code) =>
      _byCode(values, code, RequestStatus.pending, (v) => v.code);
}

/// Tipo de ausência/abono registrado para o colaborador.
enum AbsenceType {
  /// Atestado médico: abona as horas esperadas.
  medical('medical', 'Atestado médico', excuses: true),

  /// Abono concedido pelo gestor: abona as horas esperadas.
  allowance('allowance', 'Abono', excuses: true),

  /// Férias: o dia deixa de ter horas esperadas.
  vacation('vacation', 'Férias', zeroesExpected: true),

  /// Afastamento/licença (INSS, maternidade...): sem horas esperadas.
  leave('leave', 'Afastamento/licença', zeroesExpected: true),

  /// Folga compensada com o banco de horas: debita o banco.
  bankDayOff('bank_day_off', 'Folga banco de horas');

  const AbsenceType(this.code, this.label,
      {this.excuses = false, this.zeroesExpected = false});
  final String code;
  final String label;
  final bool excuses;
  final bool zeroesExpected;

  static AbsenceType fromCode(String? code) =>
      _byCode(values, code, AbsenceType.allowance, (v) => v.code);
}

/// Situação calculada de um dia no espelho de ponto.
enum DayStatus {
  normal('normal', 'Normal'),
  absent('absent', 'Falta'),
  incomplete('incomplete', 'Marcação incompleta'),
  dayOff('day_off', 'Folga/DSR'),
  holiday('holiday', 'Feriado'),
  excused('excused', 'Abonado'),
  vacation('vacation', 'Férias'),
  leave('leave', 'Afastamento'),
  bankDayOff('bank_day_off', 'Folga banco de horas'),
  open('open', 'Em andamento'),
  notEmployed('not_employed', 'Sem vínculo');

  const DayStatus(this.code, this.label);
  final String code;
  final String label;

  static DayStatus fromCode(String? code) =>
      _byCode(values, code, DayStatus.normal, (v) => v.code);
}

/// Inconsistências apontadas pelo motor de cálculo.
enum IssueType {
  missingPunch('missing_punch', 'Quantidade ímpar de marcações'),
  interjourney('interjourney', 'Interjornada inferior ao mínimo (art. 66 CLT)'),
  intrajourney(
      'intrajourney', 'Intervalo intrajornada insuficiente (art. 71 CLT)'),
  overtimeLimit('overtime_limit', 'Mais de 2h extras no dia (art. 59 CLT)'),
  late('late', 'Atraso'),
  earlyLeave('early_leave', 'Saída antecipada'),
  absent('absent', 'Falta não justificada');

  const IssueType(this.code, this.label);
  final String code;
  final String label;

  static IssueType fromCode(String? code) =>
      _byCode(values, code, IssueType.missingPunch, (v) => v.code);
}

/// Tipo de lançamento manual no banco de horas.
enum BankEntryType {
  credit('credit', 'Crédito manual'),
  debit('debit', 'Débito manual'),
  payment('payment', 'Pagamento de horas'),
  initial('initial', 'Saldo inicial');

  const BankEntryType(this.code, this.label);
  final String code;
  final String label;

  static BankEntryType fromCode(String? code) =>
      _byCode(values, code, BankEntryType.credit, (v) => v.code);
}
