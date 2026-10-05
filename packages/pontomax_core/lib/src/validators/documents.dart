/// Validadores de documentos brasileiros.
abstract final class Documents {
  static String onlyDigits(String? value) =>
      (value ?? '').replaceAll(RegExp(r'\D'), '');

  /// Mantém dígitos e letras (CNPJ alfanumérico, a partir de jul/2026).
  static String onlyAlnum(String? value) =>
      (value ?? '').toUpperCase().replaceAll(RegExp(r'[^0-9A-Z]'), '');

  static bool isValidCpf(String? value) {
    final cpf = onlyDigits(value);
    if (cpf.length != 11) return false;
    if (RegExp(r'^(\d)\1{10}$').hasMatch(cpf)) return false;
    final digits = cpf.split('').map(int.parse).toList();
    for (var j = 9; j <= 10; j++) {
      var sum = 0;
      for (var i = 0; i < j; i++) {
        sum += digits[i] * (j + 1 - i);
      }
      var dv = (sum * 10) % 11;
      if (dv == 10) dv = 0;
      if (dv != digits[j]) return false;
    }
    return true;
  }

  /// Valida CNPJ numérico ou alfanumérico (IN RFB 2.229/2024).
  static bool isValidCnpj(String? value) {
    final cnpj = onlyAlnum(value);
    if (cnpj.length != 14) return false;
    if (!RegExp(r'^[0-9A-Z]{12}\d{2}$').hasMatch(cnpj)) return false;
    if (RegExp(r'^(\d)\1{13}$').hasMatch(cnpj)) return false;
    final values = cnpj.codeUnits.map((c) => c - 48).toList();
    int dv(int length) {
      final weights = length == 12
          ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
          : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
      var sum = 0;
      for (var i = 0; i < length; i++) {
        sum += values[i] * weights[i];
      }
      final r = sum % 11;
      return r < 2 ? 0 : 11 - r;
    }

    return dv(12) == values[12] && dv(13) == values[13];
  }

  static String formatCpf(String? value) {
    final d = onlyDigits(value);
    if (d.length != 11) return value ?? '';
    return '${d.substring(0, 3)}.${d.substring(3, 6)}.${d.substring(6, 9)}-${d.substring(9)}';
  }

  static String formatCnpj(String? value) {
    final d = onlyAlnum(value);
    if (d.length != 14) return value ?? '';
    return '${d.substring(0, 2)}.${d.substring(2, 5)}.${d.substring(5, 8)}/${d.substring(8, 12)}-${d.substring(12)}';
  }

  static String formatDocument(String? value) {
    final d = onlyAlnum(value);
    return d.length == 11 ? formatCpf(d) : formatCnpj(d);
  }

  /// Gera um CPF válido a partir de 9 dígitos base (útil para dados de teste).
  static String cpfFromBase(String nineDigits) {
    final digits = onlyDigits(nineDigits)
        .padLeft(9, '0')
        .substring(0, 9)
        .split('')
        .map(int.parse)
        .toList();
    for (var j = 9; j <= 10; j++) {
      var sum = 0;
      for (var i = 0; i < j; i++) {
        sum += digits[i] * (j + 1 - i);
      }
      var dv = (sum * 10) % 11;
      if (dv == 10) dv = 0;
      digits.add(dv);
    }
    return digits.join();
  }

  /// Gera um CNPJ numérico válido a partir de 12 dígitos base.
  static String cnpjFromBase(String twelve) {
    final base = onlyDigits(twelve).padLeft(12, '0').substring(0, 12);
    final values = base.codeUnits.map((c) => c - 48).toList();
    for (final weights in [
      [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2],
      [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2],
    ]) {
      var sum = 0;
      for (var i = 0; i < weights.length; i++) {
        sum += values[i] * weights[i];
      }
      final r = sum % 11;
      values.add(r < 2 ? 0 : 11 - r);
    }
    return values.join();
  }

  static bool isValidEmail(String? value) => RegExp(
        r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$",
      ).hasMatch(value ?? '');
}
