import 'package:pontomax_core/pontomax_core.dart';
import 'package:test/test.dart';

BankMovement m(String date, int minutes) =>
    BankMovement(LocalDate.parse(date), minutes);

void main() {
  group('Banco de horas com validade (art. 59 §5º)', () {
    test('débitos compensam os créditos mais antigos (FIFO)', () {
      final r = BankLedger.compute([
        m('2026-01-10', 120),
        m('2026-02-10', 60),
        m('2026-03-01', -150),
      ], validityMonths: 6, today: const LocalDate(2026, 3, 15));
      expect(r.balance, 30);
      expect(r.openCredits.single.date, const LocalDate(2026, 2, 10));
      expect(r.openCredits.single.minutes, 30);
      expect(r.expired, 0);
    });

    test('créditos não compensados vencem após 6 meses', () {
      final r = BankLedger.compute([
        m('2026-01-10', 120),
        m('2026-05-10', 60),
      ], validityMonths: 6, today: const LocalDate(2026, 7, 20));
      expect(r.expired, 120);
      expect(r.balance, 60);
    });

    test('a vencer nos próximos 30 dias', () {
      final r = BankLedger.compute([m('2026-01-10', 90)],
          validityMonths: 6, today: const LocalDate(2026, 6, 20));
      expect(r.expiringSoon, 90);
      expect(r.openCredits.single.expiresOn, const LocalDate(2026, 7, 10));
    });

    test('saldo negativo é quitado por créditos futuros', () {
      final r = BankLedger.compute([
        m('2026-01-10', -60),
        m('2026-01-20', 100),
      ], validityMonths: 6, today: const LocalDate(2026, 2, 1));
      expect(r.debt, 0);
      expect(r.balance, 40);
    });

    test('sem validade nada vence', () {
      final r = BankLedger.compute([m('2020-01-01', 60)],
          validityMonths: 0, today: const LocalDate(2026, 1, 1));
      expect(r.expired, 0);
      expect(r.balance, 60);
      expect(r.expiringSoon, 0);
    });

    test('débito após vencimento não consome o vencido', () {
      final r = BankLedger.compute([
        m('2026-01-10', 120),
        m('2026-08-01', -60),
      ], validityMonths: 6, today: const LocalDate(2026, 8, 2));
      expect(r.expired, 120);
      expect(r.debt, 60);
      expect(r.balance, -60);
    });
  
    test('pagamento quita primeiro as horas vencidas', () {
      final r = BankLedger.compute([
        m('2026-01-10', 120),
        m('2026-07-20', 60),
        BankMovement(LocalDate.parse('2026-08-05'), -120, payment: true),
      ], validityMonths: 6, today: const LocalDate(2026, 8, 10));
      expect(r.expired, 0);
      expect(r.balance, 60);
    });
  });
}
