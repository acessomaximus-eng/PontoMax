import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../config.dart';

final _log = Logger('mail');

/// Envio de e-mails via SMTP (STARTTLS/TLS). Sem SMTP configurado, apenas
/// registra no log (útil em desenvolvimento).
class Mailer {
  final Config config;
  final List<(String, String, String)> outbox = [];

  Mailer(this.config);

  bool get configured => config.smtpHost != null;

  Future<void> send({required String to, required String subject, required String text}) async {
    outbox.add((to, subject, text));
    if (outbox.length > 50) outbox.removeAt(0);
    if (!configured) {
      _log.info('E-mail (SMTP não configurado) para $to: $subject\n$text');
      return;
    }
    try {
      await _smtp(to, subject, text);
    } catch (e, st) {
      _log.severe('Falha ao enviar e-mail para $to', e, st);
    }
  }

  Future<void> _smtp(String to, String subject, String text) async {
    final host = config.smtpHost!;
    final port = config.smtpPort;
    Socket socket = port == 465
        ? await SecureSocket.connect(host, port, timeout: const Duration(seconds: 15))
        : await Socket.connect(host, port, timeout: const Duration(seconds: 15));
    var lines = StreamIterator(socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));

    Future<String> readReply() async {
      final buffer = StringBuffer();
      while (await lines.moveNext()) {
        final line = lines.current;
        buffer.writeln(line);
        if (line.length < 4 || line[3] != '-') break;
      }
      final reply = buffer.toString();
      final code = int.tryParse(reply.length >= 3 ? reply.substring(0, 3) : '') ?? 0;
      if (code >= 400) throw StateError('SMTP: $reply');
      return reply;
    }

    Future<String> cmd(String c) async {
      socket.write('$c\r\n');
      return readReply();
    }

    await readReply();
    final ehlo = await cmd('EHLO pontomax');
    if (port != 465 && ehlo.contains('STARTTLS')) {
      await cmd('STARTTLS');
      socket = await SecureSocket.secure(socket, host: host);
      lines = StreamIterator(socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
      await cmd('EHLO pontomax');
    }
    if (config.smtpUser != null) {
      await cmd('AUTH LOGIN');
      await cmd(base64.encode(utf8.encode(config.smtpUser!)));
      await cmd(base64.encode(utf8.encode(config.smtpPassword ?? '')));
    }
    final from = RegExp(r'<([^>]+)>').firstMatch(config.mailFrom)?.group(1) ?? config.mailFrom;
    await cmd('MAIL FROM:<$from>');
    await cmd('RCPT TO:<$to>');
    await cmd('DATA');
    final encodedSubject = '=?UTF-8?B?${base64.encode(utf8.encode(subject))}?=';
    final body = text.replaceAll('\n.', '\n..');
    await cmd([
      'From: ${config.mailFrom}',
      'To: $to',
      'Subject: $encodedSubject',
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=utf-8',
      'Content-Transfer-Encoding: 8bit',
      '',
      body,
      '.',
    ].join('\r\n'));
    await cmd('QUIT');
    await socket.close();
  }
}
