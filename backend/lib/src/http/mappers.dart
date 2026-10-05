import 'package:pontomax_core/pontomax_core.dart';

import '../app.dart';
import '../db/database.dart';

String? _date(Object? v) => v is DateTime ? LocalDate.fromDateTime(v).toString() : v?.toString();

/// Conversões de linhas do banco para o contrato JSON da API.
class Mappers {
  final App app;
  Mappers(this.app);

  Map<String, Object?> user(Row r) => UserAccount(
        id: r['id'] as String,
        name: r['name'] as String,
        email: r['email'] as String,
        cpf: r['cpf'] as String?,
        phone: r['phone'] as String?,
        avatarUrl: r['avatar_url'] as String?,
        superAdmin: r['super_admin'] as bool? ?? false,
      ).toJson();

  Map<String, Object?> company(Row r) {
    final settings = (r['settings'] as Map?)?.cast<String, Object?>() ?? {};
    return {
      ...Company(
        id: r['id'] as String,
        name: r['name'] as String,
        legalName: r['legal_name'] as String? ?? '',
        documentType: r['document_type'] as String? ?? '1',
        document: r['document'] as String? ?? '',
        cnoCaepf: r['cno_caepf'] as String? ?? '',
        address: r['address'] as String? ?? '',
        city: r['city'] as String? ?? '',
        state: r['state'] as String? ?? '',
        timezone: r['timezone'] as String? ?? 'America/Sao_Paulo',
        utcOffsetMinutes: r['utc_offset_minutes'] as int? ?? -180,
        settings: CompanySettings.fromJson(settings),
        defaultScheduleId: settings['default_schedule_id'] as String?,
        createdAt: r['created_at'] is DateTime ? r['created_at'] as DateTime : null,
      ).toJson(),
    };
  }

  /// Espera colunas de `members m` + `u.name, u.email, u.cpf, u.phone` e
  /// opcionalmente `department_name`, `position_name`, `schedule_name`, `geofence_ids`.
  Map<String, Object?> member(Row r) => Member(
        id: r['id'] as String,
        companyId: r['company_id'] as String,
        userId: r['user_id'] as String,
        name: r['name'] as String? ?? '',
        email: r['email'] as String? ?? '',
        cpf: r['cpf'] as String?,
        phone: r['phone'] as String?,
        role: Role.fromCode(r['role'] as String?),
        registration: r['registration'] as String?,
        departmentId: r['department_id'] as String?,
        departmentName: r['department_name'] as String?,
        positionId: r['position_id'] as String?,
        positionName: r['position_name'] as String?,
        scheduleId: r['schedule_id'] as String?,
        scheduleName: r['schedule_name'] as String?,
        admissionDate: LocalDate.tryParse(_date(r['admission_date'])),
        dismissalDate: LocalDate.tryParse(_date(r['dismissal_date'])),
        active: r['active'] as bool? ?? true,
        badgeCode: r['badge_code'] as String?,
        hasPin: r['pin_hash'] != null,
        geofenceIds: [for (final g in (r['geofence_ids'] as List? ?? const [])) if (g != null) g.toString()],
        allowAnywhere: r['allow_anywhere'] as bool? ?? false,
        photoUrl: r['photo_url'] as String?,
        esocialRegistration: r['esocial_registration'] as String?,
        initialBankMinutes: r['initial_bank_minutes'] as int? ?? 0,
        managerId: r['manager_id'] as String?,
        createdAt: r['created_at'] as DateTime?,
      ).toJson();

  /// Espera colunas de `punches p` + opcionais `member_name`, `geofence_name`,
  /// `device_name`, `created_by_name`.
  Map<String, Object?> punch(Row r, int offset) {
    final at = r['punched_at'] as DateTime;
    return Punch(
      id: r['id'] as String,
      memberId: r['member_id'] as String,
      memberName: r['member_name'] as String?,
      nsr: r['nsr'] as int?,
      punchedAt: at,
      wall: TimeFmt.toWall(at, offset),
      recordedAt: r['recorded_at'] as DateTime?,
      source: PunchSource.fromCode(r['source'] as String?),
      method: PunchMethod.fromCode(r['method'] as String?),
      origin: PunchOrigin.fromCode(r['origin'] as String?),
      offline: r['offline'] as bool? ?? false,
      lat: r['lat'] as double?,
      lng: r['lng'] as double?,
      accuracy: r['accuracy'] as double?,
      insideGeofence: r['inside_geofence'] as bool?,
      geofenceName: r['geofence_name'] as String?,
      distance: r['distance'] as double?,
      photoUrl: app.storage.signedUrl(r['photo_file_id'] as String?),
      deviceName: r['device_name'] as String?,
      hash: r['hash'] as String?,
      disregarded: r['disregarded'] as bool? ?? false,
      disregardReason: r['disregard_reason'] as String?,
      note: r['note'] as String?,
      createdByName: r['created_by_name'] as String?,
    ).toJson();
  }

  Map<String, Object?> request(Row r) => TimeRequest(
        id: r['id'] as String,
        memberId: r['member_id'] as String,
        memberName: r['member_name'] as String?,
        type: RequestType.fromCode(r['type'] as String?),
        status: RequestStatus.fromCode(r['status'] as String?),
        date: LocalDate.fromDateTime(r['date'] as DateTime),
        endDate: r['end_date'] == null ? null : LocalDate.fromDateTime(r['end_date'] as DateTime),
        times: [for (final t in (r['times'] as List? ?? const [])) t.toString()],
        minutes: r['minutes'] as int?,
        reason: r['reason'] as String? ?? '',
        attachmentUrl: app.storage.signedUrl(r['attachment_file_id'] as String?),
        reviewerName: r['reviewer_name'] as String?,
        reviewedAt: r['reviewed_at'] as DateTime?,
        reviewNote: r['review_note'] as String?,
        createdAt: r['created_at'] as DateTime?,
      ).toJson();

  Map<String, Object?> absence(Row r) => AbsenceEntity(
        id: r['id'] as String,
        memberId: r['member_id'] as String,
        memberName: r['member_name'] as String?,
        type: AbsenceType.fromCode(r['type'] as String?),
        startDate: LocalDate.fromDateTime(r['start_date'] as DateTime),
        endDate: LocalDate.fromDateTime(r['end_date'] as DateTime),
        minutesPerDay: r['minutes_per_day'] as int?,
        reason: r['reason'] as String? ?? '',
        attachmentUrl: app.storage.signedUrl(r['attachment_file_id'] as String?),
      ).toJson();

  Map<String, Object?> bankEntry(Row r) => BankEntry(
        id: r['id'] as String,
        memberId: r['member_id'] as String,
        date: LocalDate.fromDateTime(r['date'] as DateTime),
        minutes: r['minutes'] as int,
        type: BankEntryType.fromCode(r['type'] as String?),
        description: r['description'] as String? ?? '',
        createdByName: r['created_by_name'] as String?,
        createdAt: r['created_at'] as DateTime?,
      ).toJson();

  Map<String, Object?> holiday(Row r) => HolidayEntity(
        id: r['id'] as String,
        date: LocalDate.fromDateTime(r['date'] as DateTime),
        name: r['name'] as String,
        scope: r['scope'] as String? ?? 'company',
        recurring: r['recurring'] as bool? ?? false,
      ).toJson();

  Map<String, Object?> geofence(Row r) => GeofenceEntity(
        id: r['id'] as String,
        name: r['name'] as String,
        lat: r['lat'] as double,
        lng: r['lng'] as double,
        radius: r['radius'] as double,
        address: r['address'] as String? ?? '',
        active: r['active'] as bool? ?? true,
      ).toJson();

  Map<String, Object?> device(Row r) => Device(
        id: r['id'] as String,
        name: r['name'] as String,
        geofenceId: r['geofence_id'] as String?,
        geofenceName: r['geofence_name'] as String?,
        active: r['active'] as bool? ?? true,
        lastSeenAt: r['last_seen_at'] as DateTime?,
        platform: r['platform'] as String?,
        createdAt: r['created_at'] as DateTime?,
        activationCode: r['activation_code'] as String?,
      ).toJson();

  Map<String, Object?> message(Row r) => ChatMessage(
        id: r['id'] as String,
        fromMemberId: r['from_member_id'] as String,
        fromName: r['from_name'] as String?,
        toMemberId: r['to_member_id'] as String,
        body: r['body'] as String,
        attachmentUrl: app.storage.signedUrl(r['attachment_file_id'] as String?),
        createdAt: r['created_at'] as DateTime,
        readAt: r['read_at'] as DateTime?,
      ).toJson();

  Map<String, Object?> note(Row r) => Note(
        id: r['id'] as String,
        title: r['title'] as String? ?? '',
        body: r['body'] as String? ?? '',
        pinned: r['pinned'] as bool? ?? false,
        color: r['color'] as String? ?? 'default',
        createdAt: r['created_at'] as DateTime?,
        updatedAt: r['updated_at'] as DateTime?,
      ).toJson();

  Map<String, Object?> notification(Row r) => AppNotification(
        id: r['id'] as String,
        title: r['title'] as String,
        body: r['body'] as String? ?? '',
        type: r['type'] as String? ?? 'info',
        data: (r['data'] as Map?)?.cast<String, Object?>() ?? const {},
        createdAt: r['created_at'] as DateTime,
        readAt: r['read_at'] as DateTime?,
      ).toJson();

  Map<String, Object?> audit(Row r) => AuditLog(
        id: r['id'] as String,
        actorName: r['actor_name'] as String?,
        action: r['action'] as String,
        entity: r['entity'] as String,
        entityId: r['entity_id'] as String?,
        data: (r['data'] as Map?)?.cast<String, Object?>() ?? const {},
        ip: r['ip'] as String?,
        createdAt: r['created_at'] as DateTime,
      ).toJson();

  Map<String, Object?> signature(Row r) => TimesheetSignature(
        id: r['id'] as String,
        memberId: r['member_id'] as String,
        period: r['period'] as String,
        signedAt: r['signed_at'] as DateTime,
        hash: r['hash'] as String,
        agreed: r['agreed'] as bool? ?? true,
        comment: r['comment'] as String?,
      ).toJson();
}

/// SQL base para listar colaboradores com dados agregados.
const memberSelectSql = '''
SELECT m.*, u.name, u.email, u.cpf, u.phone,
       d.name AS department_name, ps.name AS position_name, s.name AS schedule_name,
       COALESCE((SELECT array_agg(mg.geofence_id::text) FROM member_geofences mg WHERE mg.member_id = m.id), '{}') AS geofence_ids
FROM members m
JOIN users u ON u.id = m.user_id
LEFT JOIN departments d ON d.id = m.department_id
LEFT JOIN positions ps ON ps.id = m.position_id
LEFT JOIN schedules s ON s.id = m.schedule_id
''';

/// SQL base para listar marcações com nomes relacionados.
const punchSelectSql = '''
SELECT p.*, u.name AS member_name, g.name AS geofence_name, dv.name AS device_name,
       cu.name AS created_by_name
FROM punches p
JOIN members m ON m.id = p.member_id
JOIN users u ON u.id = m.user_id
LEFT JOIN geofences g ON g.id = p.geofence_id
LEFT JOIN devices dv ON dv.id = p.device_id
LEFT JOIN members cm ON cm.id = p.created_by
LEFT JOIN users cu ON cu.id = cm.user_id
''';
