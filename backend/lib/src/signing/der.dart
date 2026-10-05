import 'dart:convert';
import 'dart:typed_data';

/// Codificação DER (ASN.1) mínima para X.509, PKCS#12 e CMS.
abstract final class Der {
  static Uint8List tlv(int tag, List<int> content) {
    final header = <int>[tag];
    final len = content.length;
    if (len < 0x80) {
      header.add(len);
    } else {
      final bytes = <int>[];
      for (var l = len; l > 0; l >>= 8) {
        bytes.insert(0, l & 0xff);
      }
      header
        ..add(0x80 | bytes.length)
        ..addAll(bytes);
    }
    return concat([header, content]);
  }

  static Uint8List concat(Iterable<List<int>> parts) {
    final b = BytesBuilder(copy: false);
    for (final p in parts) {
      b.add(p);
    }
    return b.toBytes();
  }

  static Uint8List seq(Iterable<List<int>> items) => tlv(0x30, concat(items));

  /// Conteúdo de um SET OF em DER: elementos ordenados pela codificação.
  static Uint8List setContent(Iterable<List<int>> items) {
    final sorted = [for (final i in items) i]..sort(compareBytes);
    return concat(sorted);
  }

  static Uint8List set(Iterable<List<int>> items) => tlv(0x31, setContent(items));

  static int compareBytes(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  static bool equalBytes(List<int> a, List<int> b) => a.length == b.length && compareBytes(a, b) == 0;

  static Uint8List integer(BigInt v) => tlv(0x02, unsignedBytes(v, signed: true));

  static Uint8List smallInt(int v) => integer(BigInt.from(v));

  /// Inteiro não negativo em big-endian (com zero à esquerda se [signed]).
  static Uint8List unsignedBytes(BigInt v, {bool signed = false, int? length}) {
    if (v.isNegative) throw ArgumentError('Inteiro negativo');
    var hex = v.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    final bytes = <int>[for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
    if (signed && bytes.first >= 0x80) bytes.insert(0, 0);
    if (length != null) {
      while (bytes.length < length) {
        bytes.insert(0, 0);
      }
    }
    return Uint8List.fromList(bytes);
  }

  static BigInt toBigInt(List<int> bytes) {
    var r = BigInt.zero;
    for (final b in bytes) {
      r = (r << 8) | BigInt.from(b);
    }
    return r;
  }

  static Uint8List oid(String dotted) {
    final parts = dotted.split('.').map(int.parse).toList();
    final out = <int>[];
    void base128(int v) {
      final chunk = <int>[v & 0x7f];
      for (v >>= 7; v > 0; v >>= 7) {
        chunk.insert(0, (v & 0x7f) | 0x80);
      }
      out.addAll(chunk);
    }

    base128(parts[0] * 40 + parts[1]);
    parts.skip(2).forEach(base128);
    return tlv(0x06, out);
  }

  static final Uint8List nullValue = Uint8List.fromList(const [0x05, 0x00]);

  static Uint8List octets(List<int> v) => tlv(0x04, v);

  static Uint8List bitString(List<int> v, {int unusedBits = 0}) => tlv(0x03, [unusedBits, ...v]);

  static Uint8List boolean(bool v) => tlv(0x01, [v ? 0xff : 0]);

  static Uint8List utf8String(String s) => tlv(0x0c, utf8.encode(s));

  static Uint8List printableString(String s) => tlv(0x13, ascii.encode(s));

  /// UTCTime até 2049 e GeneralizedTime depois (RFC 5280).
  static Uint8List time(DateTime t) {
    final u = t.toUtc();
    String p(int n) => n.toString().padLeft(2, '0');
    final rest = '${p(u.month)}${p(u.day)}${p(u.hour)}${p(u.minute)}${p(u.second)}Z';
    return u.year < 2050 ? tlv(0x17, ascii.encode('${p(u.year % 100)}$rest')) : tlv(0x18, ascii.encode('${u.year}$rest'));
  }

  /// Tag de contexto `[n]` construída (EXPLICIT, ou IMPLICIT de SEQUENCE/SET).
  static Uint8List context(int n, List<int> content) => tlv(0xa0 | n, content);

  static Uint8List algorithm(String oid, {bool withNull = true}) => seq([Der.oid(oid), if (withNull) nullValue]);
}

/// Nó ASN.1 lido de um buffer DER (aceita comprimento indefinido do BER, comum
/// em arquivos PKCS#12 gerados pelo Windows).
class DerNode {
  final Uint8List data;
  final int tag;
  final int start;
  final int contentStart;
  final int contentEnd;
  final int end;
  final List<DerNode>? _children;

  DerNode._(this.data, this.tag, this.start, this.contentStart, this.contentEnd, this.end, this._children);

  static DerNode parse(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (data.isEmpty) throw const FormatException('ASN.1 vazio');
    return _read(data, 0);
  }

  static DerNode _read(Uint8List d, int pos) {
    if (pos + 2 > d.length) throw const FormatException('ASN.1 truncado');
    final tag = d[pos];
    if (tag & 0x1f == 0x1f) throw const FormatException('Tag ASN.1 não suportada');
    var p = pos + 1;
    var len = d[p++];
    final constructed = tag & 0x20 != 0;
    if (len == 0x80) {
      if (!constructed) throw const FormatException('Comprimento indefinido em tipo primitivo');
      final children = <DerNode>[];
      var q = p;
      while (true) {
        if (q + 2 > d.length) throw const FormatException('ASN.1 truncado');
        if (d[q] == 0 && d[q + 1] == 0) break;
        final c = _read(d, q);
        children.add(c);
        q = c.end;
      }
      return DerNode._(d, tag, pos, p, q, q + 2, children);
    }
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      if (n > 4) throw const FormatException('Comprimento ASN.1 inválido');
      len = 0;
      for (var i = 0; i < n; i++) {
        if (p >= d.length) throw const FormatException('ASN.1 truncado');
        len = (len << 8) | d[p++];
      }
    }
    final contentEnd = p + len;
    if (contentEnd > d.length) throw const FormatException('ASN.1 truncado');
    List<DerNode>? children;
    if (constructed) {
      children = [];
      var q = p;
      while (q < contentEnd) {
        final c = _read(d, q);
        children.add(c);
        q = c.end;
      }
    }
    return DerNode._(d, tag, pos, p, contentEnd, contentEnd, children);
  }

  bool get constructed => _children != null;

  List<DerNode> get children => _children ?? const [];

  int get length => children.length;

  DerNode operator [](int i) {
    if (i >= children.length) throw const FormatException('Estrutura ASN.1 inesperada');
    return children[i];
  }

  /// Codificação completa (tag + comprimento + conteúdo).
  Uint8List get raw => Uint8List.sublistView(data, start, end);

  Uint8List get content => Uint8List.sublistView(data, contentStart, contentEnd);

  /// Bytes de um OCTET STRING (inclusive a forma construída do BER).
  Uint8List get octets => constructed ? Der.concat([for (final c in children) c.octets]) : content;

  /// Bytes de um BIT STRING (sem o octeto de bits não usados).
  Uint8List get bitString => Uint8List.sublistView(data, contentStart + 1, contentEnd);

  BigInt get bigInt {
    final v = Der.toBigInt(content);
    if (content.isNotEmpty && content.first >= 0x80) return v - (BigInt.one << (content.length * 8));
    return v;
  }

  int get intValue => bigInt.toInt();

  String get oid {
    final c = content;
    final values = <int>[];
    var v = 0;
    for (final b in c) {
      v = (v << 7) | (b & 0x7f);
      if (b & 0x80 == 0) {
        values.add(v);
        v = 0;
      }
    }
    if (values.isEmpty) return '';
    final first = values.first;
    final a = first < 40 ? 0 : (first < 80 ? 1 : 2);
    return [a, first - a * 40, ...values.skip(1)].join('.');
  }

  /// Texto de UTF8String, PrintableString, IA5String, T61String ou BMPString.
  String get string {
    final c = content;
    if (tag == 0x1e) {
      return String.fromCharCodes([for (var i = 0; i + 1 < c.length; i += 2) (c[i] << 8) | c[i + 1]]);
    }
    if (tag == 0x0c) return utf8.decode(c, allowMalformed: true);
    return latin1.decode(c);
  }

  /// UTCTime ou GeneralizedTime.
  DateTime get time {
    final s = ascii.decode(content).replaceAll('Z', '');
    final full = tag == 0x17 ? '${int.parse(s.substring(0, 2)) >= 50 ? '19' : '20'}$s' : s;
    int f(int i) => int.parse(full.substring(i, i + 2));
    return DateTime.utc(int.parse(full.substring(0, 4)), f(4), f(6), f(8), f(10), full.length >= 14 ? f(12) : 0);
  }
}
