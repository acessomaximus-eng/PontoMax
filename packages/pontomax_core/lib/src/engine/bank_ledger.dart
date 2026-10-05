import '../time/local_date.dart';

/// Movimento do banco de horas (crédito positivo, débito negativo).
class BankMovement {
  final LocalDate date;
  final int minutes;

  /// Pagamento de horas: quita primeiro o saldo vencido.
  final bool payment;
  const BankMovement(this.date, this.minutes, {this.payment = false});
}

/// Crédito ainda não compensado.
class BankCredit {
  final LocalDate date;
  final int minutes;
  final LocalDate expiresOn;
  const BankCredit(this.date, this.minutes, this.expiresOn);

  Map<String, Object?> toJson() => {
        'date': date.toString(),
        'minutes': minutes,
        'expires_on': expiresOn.toString(),
      };
}

/// Resultado da apuração do banco com validade.
class BankLedgerResult {
  final int balance;

  /// Créditos vencidos e não compensados (devem ser pagos como hora extra).
  final int expired;

  /// Créditos que vencem nos próximos [BankLedger.warningDays] dias.
  final int expiringSoon;

  /// Créditos em aberto (FIFO), do mais antigo ao mais recente.
  final List<BankCredit> openCredits;

  /// Saldo negativo (horas devidas pelo colaborador).
  final int debt;

  const BankLedgerResult({
    required this.balance,
    required this.expired,
    required this.expiringSoon,
    required this.openCredits,
    required this.debt,
  });
}

/// Banco de horas com validade dos créditos (CLT art. 59 §2º e §5º).
///
/// Débitos compensam primeiro os créditos mais antigos (FIFO). Créditos não
/// compensados dentro de [validityMonths] meses vencem e passam a ser devidos
/// como horas extras. `validityMonths = 0` desativa a validade.
abstract final class BankLedger {
  static const warningDays = 30;

  static BankLedgerResult compute(
    List<BankMovement> movements, {
    required int validityMonths,
    required LocalDate today,
  }) {
    final sorted = [...movements]..sort((a, b) => a.date.compareTo(b.date));
    final credits = <(LocalDate, int)>[];
    var debt = 0;
    var expired = 0;

    void expireUntil(LocalDate date) {
      if (validityMonths <= 0) return;
      while (credits.isNotEmpty &&
          credits.first.$1.addMonths(validityMonths) <= date) {
        expired += credits.removeAt(0).$2;
      }
    }

    for (final m in sorted) {
      expireUntil(m.date);
      if (m.minutes > 0) {
        var amount = m.minutes;
        // Créditos primeiro quitam horas devidas.
        final pay = amount < debt ? amount : debt;
        debt -= pay;
        amount -= pay;
        if (amount > 0) credits.add((m.date, amount));
      } else if (m.minutes < 0) {
        var amount = -m.minutes;
        if (m.payment) {
          final paid = amount < expired ? amount : expired;
          expired -= paid;
          amount -= paid;
        }
        while (amount > 0 && credits.isNotEmpty) {
          final (d, c) = credits.first;
          if (c <= amount) {
            amount -= c;
            credits.removeAt(0);
          } else {
            credits[0] = (d, c - amount);
            amount = 0;
          }
        }
        debt += amount;
      }
    }
    expireUntil(today);

    final open = [
      for (final (d, c) in credits)
        BankCredit(
            d,
            c,
            validityMonths > 0
                ? d.addMonths(validityMonths)
                : const LocalDate(9999, 12, 31)),
    ];
    final soonLimit = today.addDays(warningDays);
    final expiringSoon = validityMonths <= 0
        ? 0
        : open
            .where((c) => c.expiresOn <= soonLimit)
            .fold<int>(0, (s, c) => s + c.minutes);
    final remaining = open.fold<int>(0, (s, c) => s + c.minutes);
    return BankLedgerResult(
      balance: remaining - debt,
      expired: expired,
      expiringSoon: expiringSoon,
      openCredits: open,
      debt: debt,
    );
  }
}
