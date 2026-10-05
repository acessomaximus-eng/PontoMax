import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pontomax_core/pontomax_core.dart';

import '../app.dart';
import '../db/database.dart';
import 'timesheet_service.dart';

/// Relatórios: espelho de ponto (PDF), comprovante (PDF), CSVs, AFD e AEJ.
class ReportService {
  final App app;
  ReportService(this.app);

  static const _brand = PdfColor.fromInt(0xFF1E3A8A);
  static const _muted = PdfColor.fromInt(0xFF6B7280);
  static const _light = PdfColor.fromInt(0xFFF3F4F6);

  pw.ThemeData? _theme;
  bool _themeLoaded = false;

  /// Fonte Noto Sans (Unicode completo) quando disponível em `assets/fonts`.
  pw.ThemeData? get theme {
    if (_themeLoaded) return _theme;
    _themeLoaded = true;
    final dir = Platform.environment['FONTS_DIR'] ?? 'assets/fonts';
    final regular = File('$dir/NotoSans-Regular.ttf');
    final bold = File('$dir/NotoSans-Bold.ttf');
    if (regular.existsSync() && bold.existsSync()) {
      _theme = pw.ThemeData.withFont(
        base: pw.Font.ttf(regular.readAsBytesSync().buffer.asByteData()),
        bold: pw.Font.ttf(bold.readAsBytesSync().buffer.asByteData()),
      );
    }
    return _theme;
  }

  RepInfo repInfo(CompanySettings s) => RepInfo(
        inpiNumber: s.inpiNumber.isEmpty ? app.config.inpiNumber : s.inpiNumber,
        developerDocument: app.config.developerDocument,
      );

  AfdEmployer employer(Row c) {
    final location =
        [c['address'], c['city'], c['state']].where((e) => e != null && e.toString().isNotEmpty).join(' - ');
    final legal = (c['legal_name'] as String? ?? '').isEmpty ? c['name'] as String : c['legal_name'] as String;
    return AfdEmployer(
      documentType: c['document_type'] as String? ?? '1',
      document: c['document'] as String? ?? '',
      cnoCaepf: c['cno_caepf'] as String? ?? '',
      name: legal,
      location: location,
    );
  }

  // -------------------------------------------------------------------------
  // PDF: espelho de ponto
  // -------------------------------------------------------------------------

  Future<Uint8List> timesheetPdf({
    required MemberTimesheetContext ctx,
    required PeriodResult result,
    Row? signature,
    int? bankBalance,
  }) async {
    final doc = pw.Document(title: 'Espelho de ponto', author: 'PontoMax', theme: theme);
    final c = ctx.company;
    final m = ctx.member;
    final emp = employer(c);
    final t = result.totals;

    String hm(int v, {bool signed = false}) => v == 0 ? '-' : TimeFmt.minutes(v, signed: signed);

    final headerStyle = const pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: PdfColors.white);
    const cellStyle = pw.TextStyle(fontSize: 7);

    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _brand),
        children: [
          for (final h in ['Data', 'Dia', 'Marcações', 'Previsto', 'Trab.', 'Saldo', 'Extras', 'Noturno', 'Ocorrências'])
            pw.Padding(padding: const pw.EdgeInsets.all(3), child: pw.Text(h, style: headerStyle)),
        ],
      ),
    ];
    var rowIndex = 0;
    for (final d in result.days) {
      final striped = rowIndex.isOdd;
      rowIndex++;
      final punches = d.punches
          .map((p) => '${TimeFmt.clock(p.time)}${p.origin == PunchOrigin.original ? '' : '(${p.origin.code})'}')
          .join(' ');
      final notes = <String>[
        if (d.holidayName != null) d.holidayName!,
        if (d.status != DayStatus.normal && d.status != DayStatus.open) d.status.label,
        for (final issue in d.issues)
          if (issue.type != IssueType.absent) issue.type.label.split(' (').first,
      ];
      rows.add(pw.TableRow(
        decoration: pw.BoxDecoration(color: striped ? _light : PdfColors.white),
        children: [
          d.date.toBr().substring(0, 5),
          TimeFmt.weekdayShort[d.date.weekday - 1],
          punches,
          hm(d.expected),
          hm(d.worked),
          hm(d.balance, signed: true),
          hm(d.overtimeTotal),
          hm(d.nightMinutes),
          notes.toSet().join('; '),
        ]
            .map((v) => pw.Padding(padding: const pw.EdgeInsets.all(3), child: pw.Text(v, style: cellStyle)))
            .toList(),
      ));
    }

    pw.Widget kv(String k, String v) => pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
          pw.Text('$k: ', style: const pw.TextStyle(fontSize: 8, color: _muted)),
          pw.Text(v, style: const pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
        ]);

    final overtimeText = t.overtime.isEmpty
        ? '-'
        : (t.overtime.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
            .map((e) => '${e.key}%: ${TimeFmt.minutes(e.value)}')
            .join('  ');

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(24),
      header: (context) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('Espelho de Ponto',
              style: const pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: _brand)),
          pw.Text('${result.from.toBr()} a ${result.to.toBr()}', style: const pw.TextStyle(fontSize: 10)),
        ]),
        pw.SizedBox(height: 6),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _light)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            kv('Empregador', '${emp.name} - ${Documents.formatDocument(emp.document)}'),
            if (emp.location.isNotEmpty) kv('Endereço', emp.location),
            kv('Colaborador', '${m['name']} - CPF ${Documents.formatCpf(m['cpf'] as String?)}'),
            kv('Matrícula / Admissão',
                '${m['registration'] ?? '-'} / ${m['admission_date'] is DateTime ? LocalDate.fromDateTime(m['admission_date'] as DateTime).toBr() : '-'}'),
            kv('Escala', '${ctx.schedule.name} (${ctx.schedule.regime.label})'),
          ]),
        ),
        pw.SizedBox(height: 6),
      ]),
      footer: (context) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('Gerado pelo PontoMax (REP-P) em ${TimeFmt.dateTimeBr(TimeFmt.toWall(app.now(), ctx.offset))}',
            style: const pw.TextStyle(fontSize: 6, color: _muted)),
        pw.Text('Página ${context.pageNumber}/${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 6, color: _muted)),
      ]),
      build: (context) => [
        pw.Table(
          columnWidths: const {
            0: pw.FixedColumnWidth(30),
            1: pw.FixedColumnWidth(22),
            2: pw.FlexColumnWidth(3),
            3: pw.FixedColumnWidth(38),
            4: pw.FixedColumnWidth(34),
            5: pw.FixedColumnWidth(36),
            6: pw.FixedColumnWidth(34),
            7: pw.FixedColumnWidth(40),
            8: pw.FlexColumnWidth(2.4),
          },
          children: rows,
        ),
        pw.SizedBox(height: 10),
        pw.Container(
          padding: const pw.EdgeInsets.all(8),
          color: _light,
          child: pw.Wrap(spacing: 16, runSpacing: 4, children: [
            kv('Previsto', TimeFmt.minutes(t.expected)),
            kv('Trabalhado', TimeFmt.minutes(t.worked)),
            kv('Abonado', TimeFmt.minutes(t.excused)),
            kv('Extras', overtimeText),
            kv('Faltas/atrasos', TimeFmt.minutes(t.deficit)),
            kv('Adicional noturno', '${TimeFmt.minutes(t.nightMinutes)} (reduzido ${TimeFmt.minutes(t.nightMinutesReduced)})'),
            kv('Banco no período', TimeFmt.minutes(t.bankDelta, signed: true)),
            if (bankBalance != null) kv('Saldo do banco', TimeFmt.minutes(bankBalance, signed: true)),
            kv('Faltas', '${t.absences} dia(s)'),
          ]),
        ),
        pw.SizedBox(height: 6),
        pw.Text('Legenda: (I) marcação incluída pelo gestor, (P) intervalo pré-assinalado.',
            style: const pw.TextStyle(fontSize: 6, color: _muted)),
        pw.SizedBox(height: 24),
        if (signature != null)
          pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _brand)),
            child: pw.Text(
              'Assinado eletronicamente pelo colaborador em '
              '${TimeFmt.dateTimeBr(TimeFmt.toWall(signature['signed_at'] as DateTime, ctx.offset))} '
              '(${signature['agreed'] == true ? 'de acordo' : 'com ressalvas: ${signature['comment'] ?? ''}'}). '
              'Hash: ${signature['hash']}',
              style: const pw.TextStyle(fontSize: 7),
            ),
          )
        else
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceAround, children: [
            for (final label in ['Assinatura do colaborador', 'Assinatura do empregador'])
              pw.Column(children: [
                pw.Container(width: 180, height: 0.5, color: PdfColors.black),
                pw.SizedBox(height: 2),
                pw.Text(label, style: const pw.TextStyle(fontSize: 7)),
              ]),
          ]),
      ],
    ));
    return doc.save();
  }

  // -------------------------------------------------------------------------
  // PDF: comprovante de registro de ponto
  // -------------------------------------------------------------------------

  /// Comprovante em PDF assinado digitalmente (PAdES, Portaria 671 art. 88).
  Future<Uint8List> receiptPdf(PunchReceipt r) async {
    final signature = await app.signing.pades('Comprovante de registro de ponto do trabalhador');
    final signer = signature.signer.identity.certificate.subjectCommonName ?? 'PontoMax';
    final doc = pw.Document(title: PunchReceipt.title, author: 'PontoMax', theme: theme);
    doc.addPage(pw.Page(
      pageFormat: const PdfPageFormat(80 * PdfPageFormat.mm, 160 * PdfPageFormat.mm,
          marginAll: 5 * PdfPageFormat.mm),
      build: (context) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Center(
          child: pw.Text(PunchReceipt.title,
              textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        ),
        pw.Divider(),
        for (final (k, v) in r.fields())
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 3),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(k, style: const pw.TextStyle(fontSize: 6, color: _muted)),
              pw.Text(v, style: pw.TextStyle(fontSize: k.startsWith('Código') ? 6 : 8, fontWeight: pw.FontWeight.bold)),
            ]),
          ),
        pw.Spacer(),
        pw.Center(
          child: pw.BarcodeWidget(
            barcode: pw.Barcode.qrCode(),
            data: 'NSR:${r.nsr};HASH:${r.hash}',
            width: 70,
            height: 70,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Signature(
          name: 'Assinatura PontoMax',
          value: signature,
          child: pw.Center(
            child: pw.Text('Assinado digitalmente por $signer',
                textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 5, color: _muted)),
          ),
        ),
      ]),
    ));
    return doc.save();
  }

  // -------------------------------------------------------------------------
  // Resumo do período (todos os colaboradores)
  // -------------------------------------------------------------------------

  Future<List<Map<String, Object?>>> summary(String companyId, LocalDate from, LocalDate to,
      {String? departmentId,
      bool includeBank = false,
      String scopeSql = '',
      Map<String, Object?> scopeParams = const {}}) async {
    final members = await app.db.query(
      '''
      SELECT m.id, u.name, u.cpf, m.registration, d.name AS department_name
      FROM members m JOIN users u ON u.id = m.user_id LEFT JOIN departments d ON d.id = m.department_id
      WHERE m.company_id = @c AND (m.active OR m.dismissal_date >= @f)
        AND (@d::uuid IS NULL OR m.department_id = @d::uuid)$scopeSql
      ORDER BY u.name''',
      {'c': companyId, 'f': from.toString(), 'd': departmentId, ...scopeParams},
    );
    final ids = [for (final m in members) m['id'] as String];
    final periods = {
      for (final p in await app.timesheets.periodMany(companyId, ids, from, to, includeBank: includeBank))
        p.memberId: p,
    };
    final out = <Map<String, Object?>>[];
    for (final m in members) {
      final id = m['id'] as String;
      final p = periods[id];
      if (p == null) continue;
      final r = p.result;
      final bank = p.bank;
      out.add({
        'member_id': id,
        'name': m['name'],
        'cpf': m['cpf'],
        'registration': m['registration'],
        'department': m['department_name'],
        ...r.totals.toJson(),
        if (bank != null) 'bank_balance': bank.balance,
        if (bank != null) 'bank_expired': bank.ledger.expired,
      });
    }
    return out;
  }

  String summaryCsv(List<Map<String, Object?>> rows) {
    String h(Object? v) => v is int ? TimeFmt.minutes(v) : '';
    // Colunas de horas extras conforme os percentuais existentes (50, 70, 100...).
    final rates = <int>{50, 100};
    for (final r in rows) {
      for (final k in ((r['overtime'] as Map?) ?? const {}).keys) {
        final rate = int.tryParse(k.toString());
        if (rate != null) rates.add(rate);
      }
    }
    final sortedRates = rates.toList()..sort();
    final b = StringBuffer()
      ..writeln([
        'Nome', 'CPF', 'Matrícula', 'Departamento', 'Previsto', 'Trabalhado', 'Abonado',
        for (final rate in sortedRates) 'Extras $rate%',
        'Extras total', 'Faltas/atrasos', 'Noturno', 'Noturno reduzido', 'Banco no período',
        'Saldo banco', 'Banco vencido (a pagar)', 'Dias de falta', 'Inconsistências',
      ].join(';'));
    for (final r in rows) {
      final ot = (r['overtime'] as Map?) ?? {};
      b.writeln([
        _csv(r['name']),
        _csv(Documents.formatCpf(r['cpf'] as String?)),
        _csv(r['registration']),
        _csv(r['department']),
        h(r['expected']),
        h(r['worked']),
        h(r['excused']),
        for (final rate in sortedRates) h(ot['$rate']),
        h(r['overtime_total']),
        h(r['deficit']),
        h(r['night_minutes']),
        h(r['night_minutes_reduced']),
        h(r['bank_delta']),
        h(r['bank_balance']),
        h(r['bank_expired']),
        r['absences'],
        r['issues'],
      ].join(';'));
    }
    return b.toString();
  }

  /// Exportação genérica para folha de pagamento (eventos em horas decimais).
  String payrollCsv(List<Map<String, Object?>> rows, Map<String, String> codes) {
    String dec(Object? minutes) => ((minutes as int? ?? 0) / 60).toStringAsFixed(2).replaceAll('.', ',');
    final b = StringBuffer()..writeln('Matricula;CPF;Nome;Evento;Descricao;Quantidade');
    for (final r in rows) {
      final ot = (r['overtime'] as Map?) ?? {};
      void add(String key, String label, Object? value, {bool days = false}) {
        if (value == null || value == 0) return;
        b.writeln([
          _csv(r['registration']),
          Documents.onlyDigits(r['cpf'] as String?),
          _csv(r['name']),
          codes[key] ?? key,
          label,
          days ? value.toString() : dec(value),
        ].join(';'));
      }

      for (final e in ot.entries) {
        add('HE${e.key}', 'Horas extras ${e.key}%', e.value);
      }
      add('ADN', 'Adicional noturno (horas reduzidas)', r['night_minutes_reduced']);
      add('FALTAS_H', 'Faltas e atrasos (horas)', r['deficit']);
      add('FALTAS_D', 'Faltas (dias)', r['absences'], days: true);
    }
    return b.toString();
  }

  String _csv(Object? v) {
    final s = (v ?? '').toString();
    return s.contains(RegExp(r'[;"\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
  }

  Future<String> punchesCsv(String companyId, LocalDate from, LocalDate to, int offset,
      {String scopeSql = '', Map<String, Object?> scopeParams = const {}}) async {
    final rows = await app.db.query(
      '''
      SELECT p.*, u.name, u.cpf, g.name AS geofence_name FROM punches p
      JOIN members m ON m.id = p.member_id JOIN users u ON u.id = m.user_id
      LEFT JOIN geofences g ON g.id = p.geofence_id
      WHERE p.company_id = @c AND p.punched_at >= @s AND p.punched_at < @e$scopeSql
      ORDER BY u.name, p.punched_at''',
      {
        ...scopeParams,
        'c': companyId,
        's': TimeFmt.fromWall(from.toDateTime(), offset),
        'e': TimeFmt.fromWall(to.addDays(1).toDateTime(), offset),
      },
    );
    final b = StringBuffer()
      ..writeln('NSR;Nome;CPF;Data;Hora;Origem;Coletor;Metodo;Offline;Latitude;Longitude;Perimetro;Dentro;Desconsiderada;Hash');
    for (final r in rows) {
      final wall = TimeFmt.toWall(r['punched_at'] as DateTime, offset);
      b.writeln([
        r['nsr'] ?? '',
        _csv(r['name']),
        Documents.formatCpf(r['cpf'] as String?),
        LocalDate.fromDateTime(wall).toBr(),
        TimeFmt.clock(wall),
        PunchOrigin.fromCode(r['origin'] as String?).label,
        PunchSource.fromCode(r['source'] as String?).label,
        PunchMethod.fromCode(r['method'] as String?).label,
        r['offline'] == true ? 'Sim' : 'Não',
        r['lat'] ?? '',
        r['lng'] ?? '',
        _csv(r['geofence_name']),
        r['inside_geofence'] == null ? '' : (r['inside_geofence'] == true ? 'Sim' : 'Não'),
        r['disregarded'] == true ? 'Sim' : 'Não',
        r['hash'] ?? '',
      ].join(';'));
    }
    return b.toString();
  }

  // -------------------------------------------------------------------------
  // AFD e AEJ (Portaria 671)
  // -------------------------------------------------------------------------

  Future<String> afd(Row company, LocalDate from, LocalDate to) async {
    final offset = company['utc_offset_minutes'] as int;
    final settings = CompanySettings.fromJson((company['settings'] as Map).cast<String, Object?>());
    final s = TimeFmt.fromWall(from.toDateTime(), offset);
    final e = TimeFmt.fromWall(to.addDays(1).toDateTime(), offset);
    final punches = await app.db.query(
      '''
      SELECT p.nsr, p.punched_at, p.recorded_at, p.source, p.offline, p.hash, u.cpf
      FROM punches p JOIN members m ON m.id = p.member_id JOIN users u ON u.id = m.user_id
      WHERE p.company_id = @c AND p.nsr IS NOT NULL AND p.recorded_at >= @s AND p.recorded_at < @e
      ORDER BY p.nsr''',
      {'c': company['id'], 's': s, 'e': e},
    );
    final events = await app.db.query(
      'SELECT * FROM rep_events WHERE company_id = @c AND recorded_at >= @s AND recorded_at < @e ORDER BY nsr',
      {'c': company['id'], 's': s, 'e': e},
    );
    final emp = employer(company);
    final records = <AfdLine>[
      for (final p in punches)
        AfdLine(
          p['nsr'] as int,
          7,
          AfdPunch(
            nsr: p['nsr'] as int,
            punchWall: TimeFmt.toWall(p['punched_at'] as DateTime, offset),
            cpf: p['cpf'] as String? ?? '',
            recordedWall: TimeFmt.toWall(p['recorded_at'] as DateTime, offset),
            collector: PunchSource.fromCode(p['source'] as String?).afdCode,
            offline: p['offline'] as bool,
            offsetMinutes: offset,
          ).toLine(p['hash'] as String),
        ),
      for (final ev in events)
        if (ev['type'] == 5)
          AfdLine(
            ev['nsr'] as int,
            5,
            AfdEmployeeEvent(
              nsr: ev['nsr'] as int,
              recordedWall: TimeFmt.toWall(ev['recorded_at'] as DateTime, offset),
              operation: ev['operation'] as String? ?? 'I',
              cpf: ev['cpf'] as String? ?? '',
              name: ev['name'] as String? ?? '',
              responsibleCpf: ev['responsible_cpf'] as String? ?? '',
              offsetMinutes: offset,
            ).toLine(),
          )
        else if (ev['type'] == 2)
          AfdLine(
            ev['nsr'] as int,
            2,
            AfdEmployerEvent(
              nsr: ev['nsr'] as int,
              recordedWall: TimeFmt.toWall(ev['recorded_at'] as DateTime, offset),
              responsibleCpf: ev['responsible_cpf'] as String? ?? '',
              employer: emp,
              offsetMinutes: offset,
            ).toLine(),
          ),
    ];
    return AfdGenerator(employer: emp, rep: repInfo(settings), offsetMinutes: offset).generate(
      start: from,
      end: to,
      generatedWall: TimeFmt.toWall(app.now(), offset),
      records: records,
    );
  }

  Future<String> aej(Row company, LocalDate from, LocalDate to) async {
    final offset = company['utc_offset_minutes'] as int;
    final settings = CompanySettings.fromJson((company['settings'] as Map).cast<String, Object?>());
    final members = await app.db.query(
      '''
      SELECT m.id, m.schedule_id, m.esocial_registration, u.name, u.cpf
      FROM members m JOIN users u ON u.id = m.user_id
      WHERE m.company_id = @c AND u.cpf IS NOT NULL AND (m.active OR m.dismissal_date >= @f)
      ORDER BY u.name''',
      {'c': company['id'], 'f': from.toString()},
    );
    final ids = [for (final m in members) m['id'] as String];
    final periods = {
      for (final p in await app.timesheets.periodMany(company['id'] as String, ids, from, to)) p.memberId: p,
    };
    // Marcações desconsideradas também constam (tpMarc = D).
    final disregarded = <String, List<Row>>{};
    for (final p in await app.db.query(
      'SELECT member_id, punched_at, origin, disregard_reason FROM punches '
      'WHERE company_id = @c AND disregarded AND punched_at >= @s AND punched_at < @e ORDER BY punched_at',
      {
        'c': company['id'],
        's': TimeFmt.fromWall(from.toDateTime(), offset),
        'e': TimeFmt.fromWall(to.addDays(1).toDateTime(), offset),
      },
    )) {
      (disregarded[p['member_id'] as String] ??= []).add(p);
    }
    final employees = <AejEmployee>[];
    final schedules = <String, AejContractSchedule>{};
    final punches = <AejPunch>[];
    final absences = <AejAbsence>[];
    var idx = 0;
    for (final m in members) {
      final period = periods[m['id'] as String];
      if (period == null) continue;
      final vid = '${++idx}';
      employees.add(AejEmployee(
        id: vid,
        cpf: m['cpf'] as String,
        name: m['name'] as String,
        esocialRegistration: m['esocial_registration'] as String?,
      ));
      final ctx = period.ctx;
      final r = period.result;
      final schedCode = '${schedules.length + 1}';
      final key = ctx.schedule.id.isEmpty ? 'default' : ctx.schedule.id;
      final sched = schedules.putIfAbsent(key, () {
        final template = ctx.schedule.days.firstWhere((d) => d.workDay, orElse: () => DayTemplate.off);
        return AejContractSchedule(schedCode, template.expectedMinutes, template.intervals);
      });
      for (final p in disregarded[m['id']] ?? const <Row>[]) {
        punches.add(AejPunch(
          employeeId: vid,
          wall: TimeFmt.toWall(p['punched_at'] as DateTime, offset),
          type: 'D',
          sequence: 0,
          source: p['origin'] as String,
          scheduleCode: sched.code,
          reason: p['disregard_reason'] as String?,
        ));
      }
      for (final d in r.days) {
        var seq = 0;
        for (var i = 0; i < d.punches.length; i++) {
          final p = d.punches[i];
          if (i.isEven) seq++;
          punches.add(AejPunch(
            employeeId: vid,
            wall: p.time,
            type: i.isEven ? 'E' : 'S',
            sequence: seq,
            source: p.origin.code,
            scheduleCode: sched.code,
          ));
        }
        if (d.status == DayStatus.dayOff) {
          absences.add(AejAbsence(employeeId: vid, type: 1, date: d.date, minutes: 0));
        }
        if (d.status == DayStatus.absent) {
          absences.add(AejAbsence(employeeId: vid, type: 2, date: d.date, minutes: d.expected));
        }
        if (d.bankDelta != 0) {
          absences.add(AejAbsence(
            employeeId: vid,
            type: 3,
            date: d.date,
            minutes: d.bankDelta.abs(),
            bankMovement: d.bankDelta > 0 ? 1 : 2,
          ));
        }
      }
    }
    return AejGenerator(employer: employer(company), rep: repInfo(settings), offsetMinutes: offset).generate(
      start: from,
      end: to,
      generatedWall: TimeFmt.toWall(app.now(), offset),
      employees: employees,
      schedules: schedules.values.toList(),
      punches: punches,
      absences: absences,
    );
  }

  /// Codifica em ISO-8859-1 (caracteres fora da tabela viram `?`).
  static List<int> latin1Bytes(String s) =>
      latin1.encode(String.fromCharCodes(s.runes.map((r) => r <= 0xFF ? r : 0x3F)));
}
