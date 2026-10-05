/// Data civil (sem horário e sem fuso), no formato `AAAA-MM-DD`.
///
/// Internamente usa [DateTime.utc] para que a aritmética de dias nunca seja
/// afetada por horário de verão.
class LocalDate implements Comparable<LocalDate> {
  final int year;
  final int month;
  final int day;

  const LocalDate(this.year, this.month, this.day);

  factory LocalDate.fromDateTime(DateTime dt) =>
      LocalDate(dt.year, dt.month, dt.day);

  /// Converte `AAAA-MM-DD` (ou um ISO-8601 completo, usando só a data).
  factory LocalDate.parse(String value) {
    final datePart = value.length >= 10 ? value.substring(0, 10) : value;
    final parts = datePart.split('-');
    if (parts.length != 3) {
      throw FormatException('Data inválida: $value');
    }
    final d = LocalDate(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
    final check = d.toDateTime();
    if (check.year != d.year || check.month != d.month || check.day != d.day) {
      throw FormatException('Data inválida: $value');
    }
    return d;
  }

  static LocalDate? tryParse(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return LocalDate.parse(value);
    } on FormatException {
      return null;
    }
  }

  /// Meia-noite desta data como "relógio de parede" (DateTime UTC ingênuo).
  DateTime toDateTime() => DateTime.utc(year, month, day);

  /// 1 = segunda ... 7 = domingo (mesma convenção de [DateTime.weekday]).
  int get weekday => toDateTime().weekday;

  LocalDate addDays(int days) =>
      LocalDate.fromDateTime(toDateTime().add(Duration(days: days)));

  LocalDate addMonths(int months) {
    final total = year * 12 + (month - 1) + months;
    final y = total ~/ 12;
    final m = total % 12 + 1;
    final lastDay = DateTime.utc(y, m + 1, 0).day;
    return LocalDate(y, m, day > lastDay ? lastDay : day);
  }

  LocalDate get firstDayOfMonth => LocalDate(year, month, 1);

  LocalDate get lastDayOfMonth =>
      LocalDate.fromDateTime(DateTime.utc(year, month + 1, 0));

  /// Diferença em dias (`this - other`).
  int differenceInDays(LocalDate other) =>
      toDateTime().difference(other.toDateTime()).inDays;

  bool isBefore(LocalDate other) => compareTo(other) < 0;
  bool isAfter(LocalDate other) => compareTo(other) > 0;

  bool operator <(LocalDate other) => compareTo(other) < 0;
  bool operator <=(LocalDate other) => compareTo(other) <= 0;
  bool operator >(LocalDate other) => compareTo(other) > 0;
  bool operator >=(LocalDate other) => compareTo(other) >= 0;

  /// Itera de `from` até `to` (inclusive).
  static Iterable<LocalDate> range(LocalDate from, LocalDate to) sync* {
    var d = from;
    while (d <= to) {
      yield d;
      d = d.addDays(1);
    }
  }

  @override
  int compareTo(LocalDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  @override
  bool operator ==(Object other) =>
      other is LocalDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  /// `AAAA-MM-DD`
  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-${_pad2(month)}-${_pad2(day)}';

  /// `DD/MM/AAAA`
  String toBr() =>
      '${_pad2(day)}/${_pad2(month)}/${year.toString().padLeft(4, '0')}';

  String toJson() => toString();
}

String _pad2(int v) => v.toString().padLeft(2, '0');

/// Utilitários de minutos e horários.
abstract final class TimeFmt {
  /// Minutos → `HH:MM` (aceita negativos e > 24h: `-01:30`, `27:00`).
  static String minutes(int totalMinutes, {bool signed = false}) {
    final neg = totalMinutes < 0;
    final abs = totalMinutes.abs();
    final h = abs ~/ 60;
    final m = abs % 60;
    final sign = neg ? '-' : (signed && totalMinutes > 0 ? '+' : '');
    return '$sign${_pad2(h)}:${_pad2(m)}';
  }

  /// `HH:MM` → minutos desde a meia-noite.
  static int parseHm(String hm) {
    final parts = hm.trim().split(':');
    if (parts.length < 2) throw FormatException('Horário inválido: $hm');
    final h = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    if (h < 0 || h > 47 || m < 0 || m > 59) {
      throw FormatException('Horário inválido: $hm');
    }
    return h * 60 + m;
  }

  /// Minutos desde a meia-noite → `HH:MM` (normalizado em 24h).
  static String hm(int minutesOfDay) {
    final v = minutesOfDay % 1440;
    return '${_pad2(v ~/ 60)}:${_pad2(v % 60)}';
  }

  /// Horário de parede `HH:MM` de um [DateTime].
  static String clock(DateTime dt) => '${_pad2(dt.hour)}:${_pad2(dt.minute)}';

  /// Horário de parede `HH:MM:SS` de um [DateTime].
  static String clockSeconds(DateTime dt) =>
      '${_pad2(dt.hour)}:${_pad2(dt.minute)}:${_pad2(dt.second)}';

  /// `DD/MM/AAAA HH:MM`
  static String dateTimeBr(DateTime dt) =>
      '${LocalDate.fromDateTime(dt).toBr()} ${clock(dt)}';

  /// Deslocamento `-0300` a partir de minutos.
  static String offset(int offsetMinutes, {bool colon = false}) {
    final sign = offsetMinutes < 0 ? '-' : '+';
    final abs = offsetMinutes.abs();
    return '$sign${_pad2(abs ~/ 60)}${colon ? ':' : ''}${_pad2(abs % 60)}';
  }

  /// Converte um instante (UTC) em "relógio de parede" ingênuo do fuso.
  static DateTime toWall(DateTime instant, int offsetMinutes) =>
      instant.toUtc().add(Duration(minutes: offsetMinutes));

  /// Converte um "relógio de parede" ingênuo em instante UTC.
  static DateTime fromWall(DateTime wall, int offsetMinutes) {
    final w = DateTime.utc(wall.year, wall.month, wall.day, wall.hour,
        wall.minute, wall.second, wall.millisecond);
    return w.subtract(Duration(minutes: offsetMinutes));
  }

  /// Trunca segundos e milissegundos (marcações têm precisão de minuto).
  static DateTime truncateToMinute(DateTime dt) =>
      DateTime.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute);

  static const weekdayNames = [
    'Segunda',
    'Terça',
    'Quarta',
    'Quinta',
    'Sexta',
    'Sábado',
    'Domingo',
  ];

  static const weekdayShort = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];

  static const monthNames = [
    'Janeiro',
    'Fevereiro',
    'Março',
    'Abril',
    'Maio',
    'Junho',
    'Julho',
    'Agosto',
    'Setembro',
    'Outubro',
    'Novembro',
    'Dezembro',
  ];
}
