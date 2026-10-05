import 'package:pontomax_core/pontomax_core.dart';

import '../app.dart';
import '../db/database.dart';
import '../http/http_utils.dart';
import '../http/mappers.dart';

class PunchInput {
  final String companyId;
  final String memberId;
  final PunchSource source;
  final PunchMethod method;
  final bool offline;
  final DateTime? clientTime;
  final String? clientId;
  final double? lat;
  final double? lng;
  final double? accuracy;
  final String? photoFileId;
  final String? deviceId;
  final String? qrToken;
  final String? note;
  final String? ip;
  final String? userAgent;

  const PunchInput({
    required this.companyId,
    required this.memberId,
    required this.source,
    this.method = PunchMethod.app,
    this.offline = false,
    this.clientTime,
    this.clientId,
    this.lat,
    this.lng,
    this.accuracy,
    this.photoFileId,
    this.deviceId,
    this.qrToken,
    this.note,
    this.ip,
    this.userAgent,
  });
}

/// Registro de marcações (REP-P): NSR sequencial por empresa, hash SHA-256
/// encadeado, geocerca, foto, QR dinâmico, anti-duplicidade e modo off-line.
class PunchService {
  final App app;
  PunchService(this.app);

  /// Registra uma marcação original (gera NSR e hash).
  Future<Row> register(PunchInput input) async {
    final now = app.now();
    final ctx = await app.db.one(
      '''
      SELECT m.*, u.cpf, u.name, c.settings, c.qr_secret, c.utc_offset_minutes
      FROM members m JOIN users u ON u.id = m.user_id JOIN companies c ON c.id = m.company_id
      WHERE m.id = @m AND m.company_id = @c''',
      {'m': input.memberId, 'c': input.companyId},
    );
    if (ctx == null) throw const ApiError.notFound('Colaborador não encontrado');
    if (ctx['active'] != true) {
      throw const ApiError.unprocessable('inactive_member', 'Colaborador inativo');
    }
    final offset = ctx['utc_offset_minutes'] as int;
    final today = LocalDate.fromDateTime(TimeFmt.toWall(now, offset));
    final dismissal = ctx['dismissal_date'] as DateTime?;
    if (dismissal != null && LocalDate.fromDateTime(dismissal) < today) {
      throw const ApiError.unprocessable('dismissed', 'Colaborador desligado');
    }
    final cpf = ctx['cpf'] as String?;
    if (cpf == null || cpf.isEmpty) {
      throw const ApiError.unprocessable(
          'cpf_required', 'CPF do colaborador não cadastrado (obrigatório para o REP-P)');
    }
    final settings = CompanySettings.fromJson((ctx['settings'] as Map).cast<String, Object?>());

    // Coletor permitido?
    final allowed = switch (input.source) {
      PunchSource.mobile => settings.allowMobile,
      PunchSource.browser => settings.allowWeb,
      PunchSource.desktop => settings.allowDesktop,
      _ => true,
    };
    if (!allowed) {
      throw ApiError.unprocessable(
          'source_not_allowed', 'Marcação por ${input.source.label.toLowerCase()} não está habilitada');
    }

    // Idempotência (sincronização off-line).
    if (input.clientId != null) {
      final existing = await app.db.one(
        'SELECT * FROM punches WHERE member_id = @m AND client_id = @cid',
        {'m': input.memberId, 'cid': input.clientId},
      );
      if (existing != null) return existing;
    }

    // Horário: servidor (online) ou do aparelho (off-line, dentro de limites).
    var punchedAt = now;
    var offline = false;
    if (input.offline && input.clientTime != null) {
      if (!settings.allowOffline) {
        throw const ApiError.unprocessable('offline_not_allowed', 'Marcação off-line não permitida');
      }
      final t = input.clientTime!.toUtc();
      if (t.isAfter(now.add(const Duration(minutes: 2))) ||
          t.isBefore(now.subtract(const Duration(days: 7)))) {
        throw const ApiError.unprocessable(
            'invalid_offline_time', 'Horário da marcação off-line fora do limite permitido');
      }
      punchedAt = t;
      offline = true;
    }

    // QR Code dinâmico do quiosque.
    String? deviceId = input.deviceId;
    String? deviceGeofence;
    var qrValid = false;
    if (input.qrToken != null) {
      final id = QrToken.verify(ctx['qr_secret'] as String, input.qrToken!, now);
      if (id == null) {
        throw const ApiError.unprocessable('invalid_qr', 'QR Code inválido ou expirado. Escaneie novamente.');
      }
      final dev = await app.db.one(
        'SELECT id, geofence_id FROM devices WHERE id = @id AND company_id = @c AND active',
        {'id': optUuid(id), 'c': input.companyId},
      );
      if (dev == null) throw const ApiError.unprocessable('invalid_qr', 'QR Code de dispositivo desconhecido');
      deviceId = dev['id'] as String;
      deviceGeofence = dev['geofence_id'] as String?;
      qrValid = true;
    } else if (deviceId != null) {
      final dev = await app.db.one('SELECT geofence_id FROM devices WHERE id = @id', {'id': deviceId});
      deviceGeofence = dev?['geofence_id'] as String?;
    }

    // Geocerca.
    final fences = await _fencesFor(input.memberId, input.companyId);
    GeoPoint? point;
    if (input.lat != null && input.lng != null) {
      point = GeoPoint(input.lat!, input.lng!);
      if (!point.isValid) throw const ApiError.badRequest('Coordenadas inválidas');
    }
    final match = Geo.match(fences, point, accuracy: input.accuracy ?? 0);
    var inside = match.inside;
    var geofenceId = match.geofence?.id;
    if (deviceGeofence != null || input.source == PunchSource.device || qrValid) {
      inside = true;
      geofenceId = deviceGeofence ?? geofenceId;
    }
    final fixedLocation = input.source == PunchSource.device || qrValid;
    final allowAnywhere = ctx['allow_anywhere'] == true;
    if (settings.requireGeofence && !allowAnywhere && !fixedLocation && fences.isNotEmpty) {
      if (point == null) {
        throw const ApiError.unprocessable(
            'location_required', 'Ative a localização do aparelho para registrar o ponto');
      }
      if (!inside) {
        final d = match.distance?.round();
        throw ApiError.unprocessable('outside_geofence',
            'Você está fora do perímetro permitido${d != null ? ' (a ${d}m de ${match.geofence?.name})' : ''}');
      }
    }

    // Foto obrigatória.
    if (settings.requirePhoto && input.photoFileId == null) {
      throw const ApiError.unprocessable('photo_required', 'A foto é obrigatória para registrar o ponto');
    }

    return app.db.tx((tx) async {
      // Bloqueia a empresa (sequência de NSR/hash) e a duplicidade.
      final company = await tx.one(
        'UPDATE companies SET last_nsr = last_nsr + 1 WHERE id = @c RETURNING last_nsr, last_hash',
        {'c': input.companyId},
      );
      final nsr = company!['last_nsr'] as int;
      final previousHash = company['last_hash'] as String;

      if (!offline && settings.minMinutesBetweenPunches > 0) {
        final dup = await tx.one(
          '''
          SELECT id FROM punches
          WHERE member_id = @m AND NOT disregarded AND origin = 'O'
            AND punched_at > @since AND punched_at <= @now''',
          {
            'm': input.memberId,
            'since': punchedAt.subtract(Duration(minutes: settings.minMinutesBetweenPunches)),
            'now': punchedAt.add(const Duration(minutes: 1)),
          },
        );
        if (dup != null) {
          throw ApiError.conflict(
              'Marcação já registrada há menos de ${settings.minMinutesBetweenPunches} minuto(s)');
        }
      }

      final afd = AfdPunch(
        nsr: nsr,
        punchWall: TimeFmt.toWall(punchedAt, offset),
        cpf: cpf,
        recordedWall: TimeFmt.toWall(now, offset),
        collector: input.source.afdCode,
        offline: offline,
        offsetMinutes: offset,
      );
      final hash = afd.computeHash(previousHash);
      await tx.execute('UPDATE companies SET last_hash = @h WHERE id = @c', {'h': hash, 'c': input.companyId});

      final row = await tx.one(
        '''
        INSERT INTO punches (company_id, member_id, nsr, punched_at, recorded_at, source, method, origin,
          offline, lat, lng, accuracy, inside_geofence, geofence_id, distance, photo_file_id, device_id,
          hash, client_id, ip, user_agent, note)
        VALUES (@c, @m, @nsr, @at, @rec, @src, @meth, 'O', @off, @lat, @lng, @acc, @inside, @g, @dist,
          @photo, @dev, @hash, @cid, @ip, @ua, @note)
        RETURNING id''',
        {
          'c': input.companyId,
          'm': input.memberId,
          'nsr': nsr,
          'at': punchedAt,
          'rec': now,
          'src': input.source.code,
          'meth': qrValid ? PunchMethod.qrCode.code : input.method.code,
          'off': offline,
          'lat': input.lat,
          'lng': input.lng,
          'acc': input.accuracy,
          'inside': fences.isEmpty && !fixedLocation ? null : inside,
          'g': geofenceId,
          'dist': match.distance,
          'photo': input.photoFileId,
          'dev': deviceId,
          'hash': hash,
          'cid': input.clientId,
          'ip': input.ip,
          'ua': input.userAgent,
          'note': input.note,
        },
      );
      return (await tx.one('$punchSelectSql WHERE p.id = @id', {'id': row!['id']}))!;
    });
  }

  /// Inclusão manual (tratamento do ponto) — não é registro do REP, logo
  /// não recebe NSR; aparece no AEJ com fonte "I".
  Future<Row> include({
    Db? db,
    required String companyId,
    required String memberId,
    required DateTime wall,
    required int offset,
    required String reason,
    required String createdBy,
    String? requestId,
  }) async {
    final d = db ?? app.db;
    final instant = TimeFmt.fromWall(wall, offset);
    final row = await d.one(
      '''
      INSERT INTO punches (company_id, member_id, punched_at, recorded_at, source, method, origin,
        note, created_by, request_id)
      VALUES (@c, @m, @at, now(), 'other', 'manual', 'I', @note, @by, @req)
      RETURNING id''',
      {
        'c': companyId,
        'm': memberId,
        'at': instant,
        'note': reason,
        'by': createdBy,
        'req': requestId,
      },
    );
    return (await d.one('$punchSelectSql WHERE p.id = @id', {'id': row!['id']}))!;
  }

  Future<List<Geofence>> _fencesFor(String memberId, String companyId) async {
    var rows = await app.db.query(
      '''
      SELECT g.* FROM geofences g JOIN member_geofences mg ON mg.geofence_id = g.id
      WHERE mg.member_id = @m AND g.active''',
      {'m': memberId},
    );
    if (rows.isEmpty) {
      rows = await app.db.query('SELECT * FROM geofences WHERE company_id = @c AND active', {'c': companyId});
    }
    return [
      for (final r in rows)
        Geofence(
          id: r['id'] as String,
          name: r['name'] as String,
          center: GeoPoint(r['lat'] as double, r['lng'] as double),
          radiusMeters: r['radius'] as double,
        ),
    ];
  }

  /// Dados do comprovante de registro de ponto.
  Future<PunchReceipt> receipt(String punchId, String companyId) async {
    final r = await app.db.one(
      '''
      SELECT p.*, u.name AS member_name, u.cpf AS member_cpf, c.name AS company_name, c.legal_name,
             c.document, c.cno_caepf, c.address, c.city, c.state, c.utc_offset_minutes, c.settings
      FROM punches p
      JOIN members m ON m.id = p.member_id
      JOIN users u ON u.id = m.user_id
      JOIN companies c ON c.id = p.company_id
      WHERE p.id = @id AND p.company_id = @c''',
      {'id': requireUuid(punchId), 'c': companyId},
    );
    if (r == null) throw const ApiError.notFound('Marcação não encontrada');
    if (r['nsr'] == null) {
      throw const ApiError.unprocessable('no_receipt', 'Marcações incluídas manualmente não geram comprovante');
    }
    final offset = r['utc_offset_minutes'] as int;
    final settings = CompanySettings.fromJson((r['settings'] as Map).cast<String, Object?>());
    final legal = (r['legal_name'] as String).isEmpty ? r['company_name'] as String : r['legal_name'] as String;
    final location = [r['address'], r['city'], r['state']]
        .where((e) => e != null && e.toString().isNotEmpty)
        .join(' - ');
    return PunchReceipt(
      employerName: legal,
      employerDocument: r['document'] as String,
      employerCnoCaepf: r['cno_caepf'] as String?,
      location: location,
      inpiNumber: settings.inpiNumber.isEmpty ? app.config.inpiNumber : settings.inpiNumber,
      employeeName: r['member_name'] as String,
      employeeCpf: r['member_cpf'] as String? ?? '',
      punchWall: TimeFmt.toWall(r['punched_at'] as DateTime, offset),
      offsetMinutes: offset,
      nsr: r['nsr'] as int,
      hash: r['hash'] as String? ?? '',
      collectorLabel: PunchSource.fromCode(r['source'] as String?).label,
      offline: r['offline'] as bool? ?? false,
      latitude: r['lat'] as double?,
      longitude: r['lng'] as double?,
    );
  }

  /// Registra evento tipo 5 (inclusão/alteração/exclusão de empregado) no REP.
  Future<void> employeeEvent({
    Db? db,
    required String companyId,
    required String memberId,
    required String operation,
    required String? cpf,
    required String name,
    required String? responsibleCpf,
  }) async {
    if (cpf == null || cpf.isEmpty) return;
    final d = db ?? app.db;
    final c = await d.one(
      'UPDATE companies SET last_nsr = last_nsr + 1 WHERE id = @c RETURNING last_nsr',
      {'c': companyId},
    );
    await d.execute(
      'INSERT INTO rep_events (company_id, nsr, type, operation, member_id, cpf, name, responsible_cpf) '
      'VALUES (@c, @nsr, 5, @op, @m, @cpf, @name, @resp)',
      {
        'c': companyId,
        'nsr': c!['last_nsr'],
        'op': operation,
        'm': memberId,
        'cpf': cpf,
        'name': name,
        'resp': responsibleCpf ?? '',
      },
    );
  }

  /// Registra evento tipo 2 (identificação do empregador) no REP.
  Future<void> employerEvent({Db? db, required String companyId, required String? responsibleCpf}) async {
    final d = db ?? app.db;
    final c = await d.one(
      'UPDATE companies SET last_nsr = last_nsr + 1 WHERE id = @c RETURNING last_nsr',
      {'c': companyId},
    );
    await d.execute(
      'INSERT INTO rep_events (company_id, nsr, type, responsible_cpf) VALUES (@c, @nsr, 2, @resp)',
      {'c': companyId, 'nsr': c!['last_nsr'], 'resp': responsibleCpf ?? ''},
    );
  }
}
