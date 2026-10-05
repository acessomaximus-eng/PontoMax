import 'package:pontomax_core/pontomax_core.dart';
import 'package:test/test.dart';

void main() {
  group('Documentos', () {
    test('CPF', () {
      expect(Documents.isValidCpf('529.982.247-25'), isTrue);
      expect(Documents.isValidCpf('529.982.247-24'), isFalse);
      expect(Documents.isValidCpf('111.111.111-11'), isFalse);
      expect(Documents.isValidCpf(Documents.cpfFromBase('123456789')), isTrue);
      expect(Documents.formatCpf('52998224725'), '529.982.247-25');
    });

    test('CNPJ numérico', () {
      expect(Documents.isValidCnpj('11.222.333/0001-81'), isTrue);
      expect(Documents.isValidCnpj('11.222.333/0001-82'), isFalse);
      expect(Documents.isValidCnpj(Documents.cnpjFromBase('123456780001')),
          isTrue);
    });

    test('CNPJ alfanumérico (2026)', () {
      expect(Documents.isValidCnpj('12.ABC.345/01DE-35'), isTrue);
      expect(Documents.isValidCnpj('12.ABC.345/01DE-36'), isFalse);
    });

    test('e-mail', () {
      expect(Documents.isValidEmail('ana@empresa.com.br'), isTrue);
      expect(Documents.isValidEmail('ana@'), isFalse);
    });
  });

  group('Feriados', () {
    test('Páscoa e feriados móveis', () {
      expect(BrazilHolidays.easter(2025), const LocalDate(2025, 4, 20));
      expect(BrazilHolidays.easter(2026), const LocalDate(2026, 4, 5));
      final n = BrazilHolidays.national(2026);
      expect(n.any((h) => h.date == const LocalDate(2026, 4, 3)), isTrue);
      expect(n.any((h) => h.date == const LocalDate(2026, 11, 20)), isTrue);
      final o = BrazilHolidays.optional(2026);
      expect(o.first.date, const LocalDate(2026, 2, 16));
      expect(o.last.date, const LocalDate(2026, 6, 4));
    });
  });

  group('Geocerca', () {
    const se = GeoPoint(-23.550520, -46.633308);
    const paulista = GeoPoint(-23.561414, -46.655881);

    test('distância aproximada', () {
      final d = se.distanceTo(paulista);
      expect(d, greaterThan(2400));
      expect(d, lessThan(2700));
    });

    test('dentro/fora do perímetro', () {
      const f = Geofence(id: '1', name: 'Sede', center: se, radiusMeters: 100);
      expect(f.contains(const GeoPoint(-23.5506, -46.6334)), isTrue);
      expect(f.contains(paulista), isFalse);
      final m = Geo.match([f], paulista);
      expect(m.inside, isFalse);
      expect(m.geofence, f);
    });
  });

  group('QR dinâmico', () {
    test('valida dentro da janela e rejeita fora', () {
      final t0 = DateTime.utc(2026, 10, 5, 12);
      final token = QrToken.generate('segredo', 'dev1', t0);
      expect(QrToken.verify('segredo', token, t0), 'dev1');
      expect(
          QrToken.verify('segredo', token, t0.add(const Duration(seconds: 30))),
          'dev1');
      expect(
          QrToken.verify('segredo', token, t0.add(const Duration(minutes: 2))),
          isNull);
      expect(QrToken.verify('outro', token, t0), isNull);
      expect(QrToken.deviceIdOf(token), 'dev1');
    });
  });

  group('Datas', () {
    test('LocalDate', () {
      const d = LocalDate(2026, 1, 31);
      expect(d.addMonths(1), const LocalDate(2026, 2, 28));
      expect(d.addDays(1), const LocalDate(2026, 2, 1));
      expect(LocalDate.parse('2026-10-05').weekday, DateTime.monday);
      expect(() => LocalDate.parse('2026-02-30'), throwsFormatException);
      expect(TimeFmt.minutes(-90), '-01:30');
      expect(TimeFmt.minutes(75, signed: true), '+01:15');
    });

    test('período de apuração com dia de fechamento', () {
      const s = CompanySettings(closingDay: 20);
      final (a, b) = s.periodFor(const LocalDate(2026, 10, 25));
      expect(a, const LocalDate(2026, 10, 21));
      expect(b, const LocalDate(2026, 11, 20));
      final (c, d) = s.periodFor(const LocalDate(2026, 10, 5));
      expect(c, const LocalDate(2026, 9, 21));
      expect(d, const LocalDate(2026, 10, 20));
      final (e, f) =
          const CompanySettings().periodFor(const LocalDate(2026, 2, 10));
      expect(e, const LocalDate(2026, 2, 1));
      expect(f, const LocalDate(2026, 2, 28));
    });

    test('conversão de fuso para relógio de parede', () {
      final instant = DateTime.utc(2026, 10, 5, 11, 0);
      final wall = TimeFmt.toWall(instant, -180);
      expect(wall.hour, 8);
      expect(TimeFmt.fromWall(wall, -180), instant);
    });
  });
}
