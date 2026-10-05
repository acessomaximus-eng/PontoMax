/// Leitura simples de CSV (separador `;` ou `,`, aspas duplas e BOM).
List<List<String>> parseCsv(String input) {
  var text = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (text.startsWith('﻿')) text = text.substring(1);
  final firstLine = text.split('\n').first;
  final sep = ';'.allMatches(firstLine).length >= ','.allMatches(firstLine).length ? ';' : ',';
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == sep) {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\n') {
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <String>[];
    } else {
      cell.write(ch);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}

/// Normaliza cabeçalhos: minúsculas, sem acentos e espaços extras.
String normalizeHeader(String h) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
  const to = 'aaaaaeeeeiiiiooooouuuucn';
  final b = StringBuffer();
  for (final r in h.trim().toLowerCase().runes) {
    final c = String.fromCharCode(r);
    final idx = from.indexOf(c);
    b.write(idx >= 0 ? to[idx] : c);
  }
  return b.toString().replaceAll(RegExp(r'\s+'), ' ');
}

/// Aceita `DD/MM/AAAA` ou `AAAA-MM-DD` e retorna `AAAA-MM-DD`.
String parseBrDate(String v) {
  final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(v.trim());
  if (m == null) return v.trim();
  return '${m.group(3)}-${m.group(2)!.padLeft(2, '0')}-${m.group(1)!.padLeft(2, '0')}';
}
