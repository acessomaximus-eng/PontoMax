import 'package:pontomax_core/pontomax_core.dart';
import 'package:test/test.dart';

void main() {
  const employer = AfdEmployer(
    documentType: '1',
    document: '11.222.333/0001-81',
    name: 'Empresa Exemplo Ltda',
    location: 'Rua A, 100 - São Paulo/SP',
  );

  group('CRC-16/KERMIT', () {
    test('valor de verificação padrão', () {
      expect(crc16Kermit('123456789'), '2189');
    });
  });

  group('AFD (Portaria 671, leiaute 003)', () {
    test('registro tipo 7 tem 137 posições e hash encadeado', () {
      final p1 = AfdPunch(
        nsr: 1,
        punchWall: DateTime.utc(2026, 10, 5, 8, 0),
        cpf: '529.982.247-25',
        recordedWall: DateTime.utc(2026, 10, 5, 8, 0, 3),
        collector: '01',
        offline: false,
        offsetMinutes: -180,
      );
      final h1 = p1.computeHash('');
      final line = p1.toLine(h1);
      expect(line.length, 137);
      expect(line.substring(0, 10), '0000000017');
      expect(line.substring(10, 34), '2026-10-05T08:00:00-0300');
      expect(line.substring(34, 46), '052998224725');
      expect(line.substring(70, 73), '010');
      expect(h1.length, 64);

      final p2 = AfdPunch(
        nsr: 2,
        punchWall: DateTime.utc(2026, 10, 5, 12, 0),
        cpf: '52998224725',
        recordedWall: DateTime.utc(2026, 10, 5, 12, 0),
        collector: '02',
        offline: true,
        offsetMinutes: -180,
      );
      final h2 = p2.computeHash(h1);
      expect(h2, isNot(p2.computeHash('')));

      const gen = AfdGenerator(employer: employer);
      final afd = gen.generate(
        start: const LocalDate(2026, 10, 1),
        end: const LocalDate(2026, 10, 31),
        generatedWall: DateTime.utc(2026, 10, 6, 9, 0),
        records: [AfdLine(2, 7, p2.toLine(h2)), AfdLine(1, 7, p1.toLine(h1))],
      );
      final lines = afd.trimRight().split('\r\n');
      expect(lines.first.length, 302);
      expect(lines[1], startsWith('000000001'));
      expect(lines.last.length, 64);
      expect(lines.last, endsWith('0000000029'));
      expect(AfdGenerator.verifyChain(afd, initialHash: ''), isEmpty);

      // Adulterar a hora de uma marcação quebra a cadeia.
      final tampered = afd.replaceFirst(
          '2026-10-05T12:00:00-0300', '2026-10-05T11:00:00-0300');
      expect(AfdGenerator.verifyChain(tampered, initialHash: ''), [2]);
      // Sem âncora, o primeiro registro é aceito e a quebra continua detectada.
      expect(AfdGenerator.verifyChain(tampered), [2]);
    });

    test('registros tipo 2 e 5 têm o tamanho do leiaute', () {
      final t5 = AfdEmployeeEvent(
        nsr: 3,
        recordedWall: DateTime.utc(2026, 10, 5, 8),
        operation: 'I',
        cpf: '52998224725',
        name: 'João da Silva',
        responsibleCpf: '52998224725',
        offsetMinutes: -180,
      ).toLine();
      expect(t5.length, 118);
      final t2 = AfdEmployerEvent(
        nsr: 4,
        recordedWall: DateTime.utc(2026, 10, 5, 8),
        responsibleCpf: '52998224725',
        employer: employer,
        offsetMinutes: -180,
      ).toLine();
      expect(t2.length, 331);
    });
  });

  group('AEJ', () {
    test('gera registros e trailer com contagens', () {
      const gen = AejGenerator(employer: employer);
      final aej = gen.generate(
        start: const LocalDate(2026, 10, 1),
        end: const LocalDate(2026, 10, 31),
        generatedWall: DateTime.utc(2026, 11, 1, 8),
        employees: const [
          AejEmployee(id: '1', cpf: '52998224725', name: 'João')
        ],
        schedules: [
          AejContractSchedule('1', 480, [
            WorkInterval.hm('08:00', '12:00'),
            WorkInterval.hm('13:00', '17:00')
          ]),
        ],
        punches: [
          AejPunch(
              employeeId: '1',
              wall: DateTime.utc(2026, 10, 5, 8),
              type: 'E',
              sequence: 1,
              source: 'O'),
          AejPunch(
              employeeId: '1',
              wall: DateTime.utc(2026, 10, 5, 17),
              type: 'S',
              sequence: 1,
              source: 'I',
              reason: 'Esquecimento'),
        ],
        absences: [
          const AejAbsence(
              employeeId: '1',
              type: 2,
              date: LocalDate(2026, 10, 6),
              minutes: 480)
        ],
      );
      final lines = aej.trimRight().split('\r\n');
      expect(lines.first, startsWith('01|1|11222333000181|'));
      expect(lines.where((l) => l.startsWith('04|')).single,
          '04|1|480|0800|1200|1300|1700');
      expect(lines.last, '99|1|1|1|1|2|0|1|1');
    });
  });

  group('Comprovante', () {
    test('contém os campos obrigatórios', () {
      final r = PunchReceipt(
        employerName: 'Empresa',
        employerDocument: '11222333000181',
        inpiNumber: '12345678901234567',
        employeeName: 'João',
        employeeCpf: '52998224725',
        punchWall: DateTime.utc(2026, 10, 5, 8, 0),
        offsetMinutes: -180,
        nsr: 15,
        hash: 'abc',
        collectorLabel: 'Aplicativo mobile',
        offline: false,
      ).toText();
      expect(r, contains('11.222.333/0001-81'));
      expect(r, contains('529.982.247-25'));
      expect(r, contains('05/10/2026 08:00'));
      expect(r, contains('000000015'));
    });
  });
}
