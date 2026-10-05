/// Entidades trafegadas pela API (contrato compartilhado backend ↔ app).
library;

import '../time/local_date.dart';
import 'enums.dart';

// ---------------------------------------------------------------------------
// Helpers de conversão
// ---------------------------------------------------------------------------

String _s(Object? v) => v?.toString() ?? '';
String? _sn(Object? v) => v?.toString();
int _i(Object? v, [int d = 0]) =>
    v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? d;
int? _in(Object? v) => v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
double? _dn(Object? v) =>
    v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
bool _b(Object? v, [bool d = false]) =>
    v is bool ? v : (v == null ? d : v.toString() == 'true');
DateTime? _dt(Object? v) =>
    v == null ? null : DateTime.tryParse(v.toString())?.toUtc();
LocalDate? _ld(Object? v) => LocalDate.tryParse(v?.toString());
List<String> _ls(Object? v) =>
    v is List ? [for (final e in v) e.toString()] : const [];
Map<String, Object?> _m(Object? v) =>
    v is Map ? v.cast<String, Object?>() : <String, Object?>{};

typedef Json = Map<String, Object?>;

// ---------------------------------------------------------------------------
// Usuário / sessão
// ---------------------------------------------------------------------------

class UserAccount {
  final String id;
  final String name;
  final String email;
  final String? cpf;
  final String? phone;
  final String? avatarUrl;
  final bool superAdmin;

  const UserAccount({
    required this.id,
    required this.name,
    required this.email,
    this.cpf,
    this.phone,
    this.avatarUrl,
    this.superAdmin = false,
  });

  factory UserAccount.fromJson(Json j) => UserAccount(
        id: _s(j['id']),
        name: _s(j['name']),
        email: _s(j['email']),
        cpf: _sn(j['cpf']),
        phone: _sn(j['phone']),
        avatarUrl: _sn(j['avatar_url']),
        superAdmin: _b(j['super_admin']),
      );

  Json toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'cpf': cpf,
        'phone': phone,
        'avatar_url': avatarUrl,
        'super_admin': superAdmin,
      };
}

/// Vínculo do usuário logado com uma empresa (para troca de empresa).
class Membership {
  final String memberId;
  final String companyId;
  final String companyName;
  final Role role;
  const Membership({
    required this.memberId,
    required this.companyId,
    required this.companyName,
    required this.role,
  });

  factory Membership.fromJson(Json j) => Membership(
        memberId: _s(j['member_id']),
        companyId: _s(j['company_id']),
        companyName: _s(j['company_name']),
        role: Role.fromCode(_sn(j['role'])),
      );

  Json toJson() => {
        'member_id': memberId,
        'company_id': companyId,
        'company_name': companyName,
        'role': role.code,
      };
}

// ---------------------------------------------------------------------------
// Empresa
// ---------------------------------------------------------------------------

class CompanySettings {
  final bool requirePhoto;
  final bool requireGeofence;
  final bool allowOffline;
  final bool allowMobile;
  final bool allowWeb;
  final bool allowDesktop;
  final bool faceCheck;

  /// Intervalo mínimo entre duas marcações do mesmo colaborador (anti-duplicidade).
  final int minMinutesBetweenPunches;

  /// Dia de fechamento do ponto (1–28). 0 = último dia do mês.
  final int closingDay;

  /// Número de registro do REP-P no INPI.
  final String inpiNumber;

  /// Lembretes de marcação habilitados por padrão.
  final bool reminders;

  /// Colaborador pode ver o próprio banco de horas.
  final bool showBankToEmployee;

  /// Exige assinatura mensal do espelho de ponto pelo colaborador.
  final bool requireTimesheetSignature;

  const CompanySettings({
    this.requirePhoto = false,
    this.requireGeofence = false,
    this.allowOffline = true,
    this.allowMobile = true,
    this.allowWeb = true,
    this.allowDesktop = true,
    this.faceCheck = false,
    this.minMinutesBetweenPunches = 1,
    this.closingDay = 0,
    this.inpiNumber = '',
    this.reminders = true,
    this.showBankToEmployee = true,
    this.requireTimesheetSignature = true,
  });

  factory CompanySettings.fromJson(Json j) => CompanySettings(
        requirePhoto: _b(j['require_photo']),
        requireGeofence: _b(j['require_geofence']),
        allowOffline: _b(j['allow_offline'], true),
        allowMobile: _b(j['allow_mobile'], true),
        allowWeb: _b(j['allow_web'], true),
        allowDesktop: _b(j['allow_desktop'], true),
        faceCheck: _b(j['face_check']),
        minMinutesBetweenPunches: _i(j['min_minutes_between_punches'], 1),
        closingDay: _i(j['closing_day']),
        inpiNumber: _s(j['inpi_number']),
        reminders: _b(j['reminders'], true),
        showBankToEmployee: _b(j['show_bank_to_employee'], true),
        requireTimesheetSignature: _b(j['require_timesheet_signature'], true),
      );

  Json toJson() => {
        'require_photo': requirePhoto,
        'require_geofence': requireGeofence,
        'allow_offline': allowOffline,
        'allow_mobile': allowMobile,
        'allow_web': allowWeb,
        'allow_desktop': allowDesktop,
        'face_check': faceCheck,
        'min_minutes_between_punches': minMinutesBetweenPunches,
        'closing_day': closingDay,
        'inpi_number': inpiNumber,
        'reminders': reminders,
        'show_bank_to_employee': showBankToEmployee,
        'require_timesheet_signature': requireTimesheetSignature,
      };

  /// Período de apuração que contém [date], respeitando o dia de fechamento.
  (LocalDate, LocalDate) periodFor(LocalDate date) {
    if (closingDay <= 0 || closingDay >= 28) {
      return (date.firstDayOfMonth, date.lastDayOfMonth);
    }
    if (date.day > closingDay) {
      final start = LocalDate(date.year, date.month, closingDay + 1);
      return (start, start.addMonths(1).addDays(-1));
    }
    final end = LocalDate(date.year, date.month, closingDay);
    return (end.addMonths(-1).addDays(1), end);
  }
}

class Company {
  final String id;
  final String name;
  final String legalName;

  /// `1` = CNPJ, `2` = CPF.
  final String documentType;
  final String document;
  final String cnoCaepf;
  final String address;
  final String city;
  final String state;
  final String timezone;
  final int utcOffsetMinutes;
  final CompanySettings settings;
  final String? defaultScheduleId;
  final DateTime? createdAt;

  const Company({
    required this.id,
    required this.name,
    this.legalName = '',
    this.documentType = '1',
    this.document = '',
    this.cnoCaepf = '',
    this.address = '',
    this.city = '',
    this.state = '',
    this.timezone = 'America/Sao_Paulo',
    this.utcOffsetMinutes = -180,
    this.settings = const CompanySettings(),
    this.defaultScheduleId,
    this.createdAt,
  });

  factory Company.fromJson(Json j) => Company(
        id: _s(j['id']),
        name: _s(j['name']),
        legalName: _s(j['legal_name']),
        documentType: _sn(j['document_type']) ?? '1',
        document: _s(j['document']),
        cnoCaepf: _s(j['cno_caepf']),
        address: _s(j['address']),
        city: _s(j['city']),
        state: _s(j['state']),
        timezone: _sn(j['timezone']) ?? 'America/Sao_Paulo',
        utcOffsetMinutes: _i(j['utc_offset_minutes'], -180),
        settings: CompanySettings.fromJson(_m(j['settings'])),
        defaultScheduleId: _sn(j['default_schedule_id']) ?? _sn(_m(j['settings'])['default_schedule_id']),
        createdAt: _dt(j['created_at']),
      );

  Json toJson() => {
        'id': id,
        'name': name,
        'legal_name': legalName,
        'document_type': documentType,
        'document': document,
        'cno_caepf': cnoCaepf,
        'address': address,
        'city': city,
        'state': state,
        'timezone': timezone,
        'utc_offset_minutes': utcOffsetMinutes,
        'settings': settings.toJson(),
        'default_schedule_id': defaultScheduleId,
        'created_at': createdAt?.toIso8601String(),
      };
}

// ---------------------------------------------------------------------------
// Colaborador (vínculo)
// ---------------------------------------------------------------------------

class Member {
  final String id;
  final String companyId;
  final String userId;
  final String name;
  final String email;
  final String? cpf;
  final String? phone;
  final Role role;
  final String? registration;
  final String? departmentId;
  final String? departmentName;
  final String? positionId;
  final String? positionName;
  final String? scheduleId;
  final String? scheduleName;
  final LocalDate? admissionDate;
  final LocalDate? dismissalDate;
  final bool active;
  final String? badgeCode;
  final bool hasPin;
  final List<String> geofenceIds;

  /// Pode marcar fora dos perímetros (trabalho externo/remoto).
  final bool allowAnywhere;
  final String? photoUrl;
  final String? esocialRegistration;
  final int initialBankMinutes;
  final String? managerId;
  final DateTime? createdAt;

  const Member({
    required this.id,
    required this.companyId,
    required this.userId,
    required this.name,
    required this.email,
    this.cpf,
    this.phone,
    this.role = Role.employee,
    this.registration,
    this.departmentId,
    this.departmentName,
    this.positionId,
    this.positionName,
    this.scheduleId,
    this.scheduleName,
    this.admissionDate,
    this.dismissalDate,
    this.active = true,
    this.badgeCode,
    this.hasPin = false,
    this.geofenceIds = const [],
    this.allowAnywhere = false,
    this.photoUrl,
    this.esocialRegistration,
    this.initialBankMinutes = 0,
    this.managerId,
    this.createdAt,
  });

  String get firstName => name.split(' ').first;

  String get initials {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  factory Member.fromJson(Json j) => Member(
        id: _s(j['id']),
        companyId: _s(j['company_id']),
        userId: _s(j['user_id']),
        name: _s(j['name']),
        email: _s(j['email']),
        cpf: _sn(j['cpf']),
        phone: _sn(j['phone']),
        role: Role.fromCode(_sn(j['role'])),
        registration: _sn(j['registration']),
        departmentId: _sn(j['department_id']),
        departmentName: _sn(j['department_name']),
        positionId: _sn(j['position_id']),
        positionName: _sn(j['position_name']),
        scheduleId: _sn(j['schedule_id']),
        scheduleName: _sn(j['schedule_name']),
        admissionDate: _ld(j['admission_date']),
        dismissalDate: _ld(j['dismissal_date']),
        active: _b(j['active'], true),
        badgeCode: _sn(j['badge_code']),
        hasPin: _b(j['has_pin']),
        geofenceIds: _ls(j['geofence_ids']),
        allowAnywhere: _b(j['allow_anywhere']),
        photoUrl: _sn(j['photo_url']),
        esocialRegistration: _sn(j['esocial_registration']),
        initialBankMinutes: _i(j['initial_bank_minutes']),
        managerId: _sn(j['manager_id']),
        createdAt: _dt(j['created_at']),
      );

  Json toJson() => {
        'id': id,
        'company_id': companyId,
        'user_id': userId,
        'name': name,
        'email': email,
        'cpf': cpf,
        'phone': phone,
        'role': role.code,
        'registration': registration,
        'department_id': departmentId,
        'department_name': departmentName,
        'position_id': positionId,
        'position_name': positionName,
        'schedule_id': scheduleId,
        'schedule_name': scheduleName,
        'admission_date': admissionDate?.toString(),
        'dismissal_date': dismissalDate?.toString(),
        'active': active,
        'badge_code': badgeCode,
        'has_pin': hasPin,
        'geofence_ids': geofenceIds,
        'allow_anywhere': allowAnywhere,
        'photo_url': photoUrl,
        'esocial_registration': esocialRegistration,
        'initial_bank_minutes': initialBankMinutes,
        'manager_id': managerId,
        'created_at': createdAt?.toIso8601String(),
      };
}

// ---------------------------------------------------------------------------
// Cadastros auxiliares
// ---------------------------------------------------------------------------

class NamedEntity {
  final String id;
  final String name;
  final String? description;
  final int count;
  const NamedEntity(
      {required this.id, required this.name, this.description, this.count = 0});

  factory NamedEntity.fromJson(Json j) => NamedEntity(
        id: _s(j['id']),
        name: _s(j['name']),
        description: _sn(j['description']),
        count: _i(j['count']),
      );

  Json toJson() =>
      {'id': id, 'name': name, 'description': description, 'count': count};
}

class HolidayEntity {
  final String id;
  final LocalDate date;
  final String name;

  /// `national`, `state`, `city` ou `company`.
  final String scope;
  final bool recurring;

  const HolidayEntity({
    required this.id,
    required this.date,
    required this.name,
    this.scope = 'company',
    this.recurring = false,
  });

  factory HolidayEntity.fromJson(Json j) => HolidayEntity(
        id: _s(j['id']),
        date: _ld(j['date']) ?? const LocalDate(2000, 1, 1),
        name: _s(j['name']),
        scope: _sn(j['scope']) ?? 'company',
        recurring: _b(j['recurring']),
      );

  Json toJson() => {
        'id': id,
        'date': date.toString(),
        'name': name,
        'scope': scope,
        'recurring': recurring,
      };
}

class GeofenceEntity {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final double radius;
  final String address;
  final bool active;
  final String? qrSecret;

  const GeofenceEntity({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.radius = 150,
    this.address = '',
    this.active = true,
    this.qrSecret,
  });

  factory GeofenceEntity.fromJson(Json j) => GeofenceEntity(
        id: _s(j['id']),
        name: _s(j['name']),
        lat: _dn(j['lat']) ?? 0,
        lng: _dn(j['lng']) ?? 0,
        radius: _dn(j['radius']) ?? 150,
        address: _s(j['address']),
        active: _b(j['active'], true),
        qrSecret: _sn(j['qr_secret']),
      );

  Json toJson() => {
        'id': id,
        'name': name,
        'lat': lat,
        'lng': lng,
        'radius': radius,
        'address': address,
        'active': active,
        if (qrSecret != null) 'qr_secret': qrSecret,
      };
}

class Device {
  final String id;
  final String name;
  final String? geofenceId;
  final String? geofenceName;
  final bool active;
  final DateTime? lastSeenAt;
  final String? platform;
  final DateTime? createdAt;

  /// Retornado apenas na criação (ativação do quiosque).
  final String? activationCode;

  const Device({
    required this.id,
    required this.name,
    this.geofenceId,
    this.geofenceName,
    this.active = true,
    this.lastSeenAt,
    this.platform,
    this.createdAt,
    this.activationCode,
  });

  factory Device.fromJson(Json j) => Device(
        id: _s(j['id']),
        name: _s(j['name']),
        geofenceId: _sn(j['geofence_id']),
        geofenceName: _sn(j['geofence_name']),
        active: _b(j['active'], true),
        lastSeenAt: _dt(j['last_seen_at']),
        platform: _sn(j['platform']),
        createdAt: _dt(j['created_at']),
        activationCode: _sn(j['activation_code']),
      );

  Json toJson() => {
        'id': id,
        'name': name,
        'geofence_id': geofenceId,
        'geofence_name': geofenceName,
        'active': active,
        'last_seen_at': lastSeenAt?.toIso8601String(),
        'platform': platform,
        'created_at': createdAt?.toIso8601String(),
        if (activationCode != null) 'activation_code': activationCode,
      };
}

class ScheduleEntity {
  final String id;
  final String name;
  final Json definition;
  final int membersCount;
  const ScheduleEntity(
      {required this.id,
      required this.name,
      required this.definition,
      this.membersCount = 0});

  factory ScheduleEntity.fromJson(Json j) => ScheduleEntity(
        id: _s(j['id']),
        name: _s(j['name']),
        definition: _m(j['definition']),
        membersCount: _i(j['members_count']),
      );

  Json toJson() => {
        'id': id,
        'name': name,
        'definition': definition,
        'members_count': membersCount
      };
}

// ---------------------------------------------------------------------------
// Marcações
// ---------------------------------------------------------------------------

class Punch {
  final String id;
  final String memberId;
  final String? memberName;
  final int? nsr;

  /// Instante UTC da marcação.
  final DateTime punchedAt;

  /// Relógio de parede no fuso da empresa (ISO sem fuso).
  final DateTime wall;
  final DateTime? recordedAt;
  final PunchSource source;
  final PunchMethod method;
  final PunchOrigin origin;
  final bool offline;
  final double? lat;
  final double? lng;
  final double? accuracy;
  final bool? insideGeofence;
  final String? geofenceName;
  final double? distance;
  final String? photoUrl;
  final String? deviceName;
  final String? hash;
  final bool disregarded;
  final String? disregardReason;
  final String? note;
  final String? createdByName;

  const Punch({
    required this.id,
    required this.memberId,
    this.memberName,
    this.nsr,
    required this.punchedAt,
    required this.wall,
    this.recordedAt,
    this.source = PunchSource.mobile,
    this.method = PunchMethod.app,
    this.origin = PunchOrigin.original,
    this.offline = false,
    this.lat,
    this.lng,
    this.accuracy,
    this.insideGeofence,
    this.geofenceName,
    this.distance,
    this.photoUrl,
    this.deviceName,
    this.hash,
    this.disregarded = false,
    this.disregardReason,
    this.note,
    this.createdByName,
  });

  factory Punch.fromJson(Json j) => Punch(
        id: _s(j['id']),
        memberId: _s(j['member_id']),
        memberName: _sn(j['member_name']),
        nsr: _in(j['nsr']),
        punchedAt: _dt(j['punched_at']) ?? DateTime.now().toUtc(),
        wall: DateTime.tryParse('${_s(j['wall']).replaceAll('Z', '')}Z') ??
            DateTime.now().toUtc(),
        recordedAt: _dt(j['recorded_at']),
        source: PunchSource.fromCode(_sn(j['source'])),
        method: PunchMethod.fromCode(_sn(j['method'])),
        origin: PunchOrigin.fromCode(_sn(j['origin'])),
        offline: _b(j['offline']),
        lat: _dn(j['lat']),
        lng: _dn(j['lng']),
        accuracy: _dn(j['accuracy']),
        insideGeofence:
            j['inside_geofence'] == null ? null : _b(j['inside_geofence']),
        geofenceName: _sn(j['geofence_name']),
        distance: _dn(j['distance']),
        photoUrl: _sn(j['photo_url']),
        deviceName: _sn(j['device_name']),
        hash: _sn(j['hash']),
        disregarded: _b(j['disregarded']),
        disregardReason: _sn(j['disregard_reason']),
        note: _sn(j['note']),
        createdByName: _sn(j['created_by_name']),
      );

  Json toJson() => {
        'id': id,
        'member_id': memberId,
        'member_name': memberName,
        'nsr': nsr,
        'punched_at': punchedAt.toUtc().toIso8601String(),
        'wall': wall.toIso8601String().replaceAll('Z', ''),
        'recorded_at': recordedAt?.toUtc().toIso8601String(),
        'source': source.code,
        'method': method.code,
        'origin': origin.code,
        'offline': offline,
        'lat': lat,
        'lng': lng,
        'accuracy': accuracy,
        'inside_geofence': insideGeofence,
        'geofence_name': geofenceName,
        'distance': distance,
        'photo_url': photoUrl,
        'device_name': deviceName,
        'hash': hash,
        'disregarded': disregarded,
        'disregard_reason': disregardReason,
        'note': note,
        'created_by_name': createdByName,
      };
}

// ---------------------------------------------------------------------------
// Solicitações, ausências e banco de horas
// ---------------------------------------------------------------------------

class TimeRequest {
  final String id;
  final String memberId;
  final String? memberName;
  final RequestType type;
  final RequestStatus status;
  final LocalDate date;
  final LocalDate? endDate;

  /// Horários solicitados (`HH:MM`) para inclusão de marcações.
  final List<String> times;

  /// Minutos por dia (abono parcial). `null` = dia inteiro.
  final int? minutes;
  final String reason;
  final String? attachmentUrl;
  final String? reviewerName;
  final DateTime? reviewedAt;
  final String? reviewNote;
  final DateTime? createdAt;

  const TimeRequest({
    required this.id,
    required this.memberId,
    this.memberName,
    required this.type,
    this.status = RequestStatus.pending,
    required this.date,
    this.endDate,
    this.times = const [],
    this.minutes,
    this.reason = '',
    this.attachmentUrl,
    this.reviewerName,
    this.reviewedAt,
    this.reviewNote,
    this.createdAt,
  });

  factory TimeRequest.fromJson(Json j) => TimeRequest(
        id: _s(j['id']),
        memberId: _s(j['member_id']),
        memberName: _sn(j['member_name']),
        type: RequestType.fromCode(_sn(j['type'])),
        status: RequestStatus.fromCode(_sn(j['status'])),
        date: _ld(j['date']) ?? const LocalDate(2000, 1, 1),
        endDate: _ld(j['end_date']),
        times: _ls(j['times']),
        minutes: _in(j['minutes']),
        reason: _s(j['reason']),
        attachmentUrl: _sn(j['attachment_url']),
        reviewerName: _sn(j['reviewer_name']),
        reviewedAt: _dt(j['reviewed_at']),
        reviewNote: _sn(j['review_note']),
        createdAt: _dt(j['created_at']),
      );

  Json toJson() => {
        'id': id,
        'member_id': memberId,
        'member_name': memberName,
        'type': type.code,
        'status': status.code,
        'date': date.toString(),
        'end_date': endDate?.toString(),
        'times': times,
        'minutes': minutes,
        'reason': reason,
        'attachment_url': attachmentUrl,
        'reviewer_name': reviewerName,
        'reviewed_at': reviewedAt?.toIso8601String(),
        'review_note': reviewNote,
        'created_at': createdAt?.toIso8601String(),
      };
}

class AbsenceEntity {
  final String id;
  final String memberId;
  final String? memberName;
  final AbsenceType type;
  final LocalDate startDate;
  final LocalDate endDate;
  final int? minutesPerDay;
  final String reason;
  final String? attachmentUrl;

  const AbsenceEntity({
    required this.id,
    required this.memberId,
    this.memberName,
    required this.type,
    required this.startDate,
    required this.endDate,
    this.minutesPerDay,
    this.reason = '',
    this.attachmentUrl,
  });

  factory AbsenceEntity.fromJson(Json j) => AbsenceEntity(
        id: _s(j['id']),
        memberId: _s(j['member_id']),
        memberName: _sn(j['member_name']),
        type: AbsenceType.fromCode(_sn(j['type'])),
        startDate: _ld(j['start_date']) ?? const LocalDate(2000, 1, 1),
        endDate: _ld(j['end_date']) ?? const LocalDate(2000, 1, 1),
        minutesPerDay: _in(j['minutes_per_day']),
        reason: _s(j['reason']),
        attachmentUrl: _sn(j['attachment_url']),
      );

  Json toJson() => {
        'id': id,
        'member_id': memberId,
        'member_name': memberName,
        'type': type.code,
        'start_date': startDate.toString(),
        'end_date': endDate.toString(),
        'minutes_per_day': minutesPerDay,
        'reason': reason,
        'attachment_url': attachmentUrl,
      };
}

class BankEntry {
  final String id;
  final String memberId;
  final LocalDate date;
  final int minutes;
  final BankEntryType type;
  final String description;
  final String? createdByName;
  final DateTime? createdAt;

  const BankEntry({
    required this.id,
    required this.memberId,
    required this.date,
    required this.minutes,
    required this.type,
    this.description = '',
    this.createdByName,
    this.createdAt,
  });

  factory BankEntry.fromJson(Json j) => BankEntry(
        id: _s(j['id']),
        memberId: _s(j['member_id']),
        date: _ld(j['date']) ?? const LocalDate(2000, 1, 1),
        minutes: _i(j['minutes']),
        type: BankEntryType.fromCode(_sn(j['type'])),
        description: _s(j['description']),
        createdByName: _sn(j['created_by_name']),
        createdAt: _dt(j['created_at']),
      );

  Json toJson() => {
        'id': id,
        'member_id': memberId,
        'date': date.toString(),
        'minutes': minutes,
        'type': type.code,
        'description': description,
        'created_by_name': createdByName,
        'created_at': createdAt?.toIso8601String(),
      };
}

// ---------------------------------------------------------------------------
// Comunicação
// ---------------------------------------------------------------------------

class ChatMessage {
  final String id;
  final String fromMemberId;
  final String? fromName;
  final String toMemberId;
  final String body;
  final String? attachmentUrl;
  final DateTime createdAt;
  final DateTime? readAt;

  const ChatMessage({
    required this.id,
    required this.fromMemberId,
    this.fromName,
    required this.toMemberId,
    required this.body,
    this.attachmentUrl,
    required this.createdAt,
    this.readAt,
  });

  factory ChatMessage.fromJson(Json j) => ChatMessage(
        id: _s(j['id']),
        fromMemberId: _s(j['from_member_id']),
        fromName: _sn(j['from_name']),
        toMemberId: _s(j['to_member_id']),
        body: _s(j['body']),
        attachmentUrl: _sn(j['attachment_url']),
        createdAt: _dt(j['created_at']) ?? DateTime.now().toUtc(),
        readAt: _dt(j['read_at']),
      );

  Json toJson() => {
        'id': id,
        'from_member_id': fromMemberId,
        'from_name': fromName,
        'to_member_id': toMemberId,
        'body': body,
        'attachment_url': attachmentUrl,
        'created_at': createdAt.toIso8601String(),
        'read_at': readAt?.toIso8601String(),
      };
}

class Conversation {
  final String memberId;
  final String name;
  final String? photoUrl;
  final String? lastMessage;
  final DateTime? lastAt;
  final int unread;
  const Conversation({
    required this.memberId,
    required this.name,
    this.photoUrl,
    this.lastMessage,
    this.lastAt,
    this.unread = 0,
  });

  factory Conversation.fromJson(Json j) => Conversation(
        memberId: _s(j['member_id']),
        name: _s(j['name']),
        photoUrl: _sn(j['photo_url']),
        lastMessage: _sn(j['last_message']),
        lastAt: _dt(j['last_at']),
        unread: _i(j['unread']),
      );

  Json toJson() => {
        'member_id': memberId,
        'name': name,
        'photo_url': photoUrl,
        'last_message': lastMessage,
        'last_at': lastAt?.toIso8601String(),
        'unread': unread,
      };
}

class Note {
  final String id;
  final String title;
  final String body;
  final bool pinned;
  final String color;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Note({
    required this.id,
    required this.title,
    this.body = '',
    this.pinned = false,
    this.color = 'default',
    this.createdAt,
    this.updatedAt,
  });

  factory Note.fromJson(Json j) => Note(
        id: _s(j['id']),
        title: _s(j['title']),
        body: _s(j['body']),
        pinned: _b(j['pinned']),
        color: _sn(j['color']) ?? 'default',
        createdAt: _dt(j['created_at']),
        updatedAt: _dt(j['updated_at']),
      );

  Json toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'pinned': pinned,
        'color': color,
        'created_at': createdAt?.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      };
}

class AppNotification {
  final String id;
  final String title;
  final String body;
  final String type;
  final Json data;
  final DateTime createdAt;
  final DateTime? readAt;

  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    this.data = const {},
    required this.createdAt,
    this.readAt,
  });

  factory AppNotification.fromJson(Json j) => AppNotification(
        id: _s(j['id']),
        title: _s(j['title']),
        body: _s(j['body']),
        type: _s(j['type']),
        data: _m(j['data']),
        createdAt: _dt(j['created_at']) ?? DateTime.now().toUtc(),
        readAt: _dt(j['read_at']),
      );

  Json toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'type': type,
        'data': data,
        'created_at': createdAt.toIso8601String(),
        'read_at': readAt?.toIso8601String(),
      };
}

class AuditLog {
  final String id;
  final String? actorName;
  final String action;
  final String entity;
  final String? entityId;
  final Json data;
  final String? ip;
  final DateTime createdAt;

  const AuditLog({
    required this.id,
    this.actorName,
    required this.action,
    required this.entity,
    this.entityId,
    this.data = const {},
    this.ip,
    required this.createdAt,
  });

  factory AuditLog.fromJson(Json j) => AuditLog(
        id: _s(j['id']),
        actorName: _sn(j['actor_name']),
        action: _s(j['action']),
        entity: _s(j['entity']),
        entityId: _sn(j['entity_id']),
        data: _m(j['data']),
        ip: _sn(j['ip']),
        createdAt: _dt(j['created_at']) ?? DateTime.now().toUtc(),
      );

  Json toJson() => {
        'id': id,
        'actor_name': actorName,
        'action': action,
        'entity': entity,
        'entity_id': entityId,
        'data': data,
        'ip': ip,
        'created_at': createdAt.toIso8601String(),
      };
}

class TimesheetSignature {
  final String id;
  final String memberId;
  final String period;
  final DateTime signedAt;
  final String hash;
  final bool agreed;
  final String? comment;

  const TimesheetSignature({
    required this.id,
    required this.memberId,
    required this.period,
    required this.signedAt,
    required this.hash,
    this.agreed = true,
    this.comment,
  });

  factory TimesheetSignature.fromJson(Json j) => TimesheetSignature(
        id: _s(j['id']),
        memberId: _s(j['member_id']),
        period: _s(j['period']),
        signedAt: _dt(j['signed_at']) ?? DateTime.now().toUtc(),
        hash: _s(j['hash']),
        agreed: _b(j['agreed'], true),
        comment: _sn(j['comment']),
      );

  Json toJson() => {
        'id': id,
        'member_id': memberId,
        'period': period,
        'signed_at': signedAt.toIso8601String(),
        'hash': hash,
        'agreed': agreed,
        'comment': comment,
      };
}
