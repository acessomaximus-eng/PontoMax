import '../time/local_date.dart';
import 'calculator.dart';

/// Feriados nacionais brasileiros (Lei 662/1949, Lei 6.802/1980,
/// Lei 14.759/2023) e pontos facultativos móveis.
abstract final class BrazilHolidays {
  /// Domingo de Páscoa (algoritmo de Meeus/Jones/Butcher).
  static LocalDate easter(int year) {
    final a = year % 19;
    final b = year ~/ 100;
    final c = year % 100;
    final d = b ~/ 4;
    final e = b % 4;
    final f = (b + 8) ~/ 25;
    final g = (b - f + 1) ~/ 3;
    final h = (19 * a + b - d - g + 15) % 30;
    final i = c ~/ 4;
    final k = c % 4;
    final l = (32 + 2 * e + 2 * i - h - k) % 7;
    final m = (a + 11 * h + 22 * l) ~/ 451;
    final month = (h + l - 7 * m + 114) ~/ 31;
    final day = ((h + l - 7 * m + 114) % 31) + 1;
    return LocalDate(year, month, day);
  }

  /// Feriados nacionais do ano.
  static List<Holiday> national(int year) {
    final easterSunday = easter(year);
    return [
      Holiday(LocalDate(year, 1, 1), 'Confraternização Universal'),
      Holiday(easterSunday.addDays(-2), 'Sexta-feira Santa'),
      Holiday(LocalDate(year, 4, 21), 'Tiradentes'),
      Holiday(LocalDate(year, 5, 1), 'Dia do Trabalho'),
      Holiday(LocalDate(year, 9, 7), 'Independência do Brasil'),
      Holiday(LocalDate(year, 10, 12), 'Nossa Senhora Aparecida'),
      Holiday(LocalDate(year, 11, 2), 'Finados'),
      Holiday(LocalDate(year, 11, 15), 'Proclamação da República'),
      if (year >= 2024)
        Holiday(LocalDate(year, 11, 20),
            'Dia Nacional de Zumbi e da Consciência Negra'),
      Holiday(LocalDate(year, 12, 25), 'Natal'),
    ]..sort((a, b) => a.date.compareTo(b.date));
  }

  /// Pontos facultativos móveis (Carnaval e Corpus Christi).
  static List<Holiday> optional(int year) {
    final e = easter(year);
    return [
      Holiday(e.addDays(-48), 'Carnaval (segunda-feira)'),
      Holiday(e.addDays(-47), 'Carnaval (terça-feira)'),
      Holiday(e.addDays(60), 'Corpus Christi'),
    ];
  }
}
