import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../http/http_utils.dart';
import '../http/mappers.dart';

/// Work chat, bloco de notas, notificações e arquivos.
class SocialRoutes {
  final App app;
  SocialRoutes(this.app);
  Mappers get map => Mappers(app);

  static const _messageSelect = '''
SELECT msg.*, u.name AS from_name FROM messages msg
JOIN members fm ON fm.id = msg.from_member_id JOIN users u ON u.id = fm.user_id
''';

  Router get router => Router()
    ..get('/chat/conversations', _conversations)
    ..get('/chat/<memberId>/messages', _messages)
    ..post('/chat/<memberId>/messages', _send)
    ..post('/chat/<memberId>/read', _markRead)
    ..get('/events/wait', _wait)
    ..get('/notes', _listNotes)
    ..post('/notes', _createNote)
    ..put('/notes/<id>', _updateNote)
    ..delete('/notes/<id>', _deleteNote)
    ..get('/notifications', _notifications)
    ..post('/notifications/read-all', _readAll)
    ..post('/notifications/<id>/read', _readOne)
    ..post('/files', _upload)
    ..get('/files/<id>', _download);

  // ---------------------------------------------------------------------------
  // Chat
  // ---------------------------------------------------------------------------

  Future<Response> _conversations(Request req) async {
    final ctx = await app.sessions.member(req);
    // Colaborador conversa com gestores; gestor conversa com todos.
    final rows = await app.db.query(
      '''
      SELECT m.id AS member_id, u.name, m.photo_url, m.role,
        (SELECT body FROM messages x WHERE (x.from_member_id = m.id AND x.to_member_id = @me)
            OR (x.from_member_id = @me AND x.to_member_id = m.id) ORDER BY x.created_at DESC LIMIT 1) AS last_message,
        (SELECT max(created_at) FROM messages x WHERE (x.from_member_id = m.id AND x.to_member_id = @me)
            OR (x.from_member_id = @me AND x.to_member_id = m.id)) AS last_at,
        (SELECT count(*)::int FROM messages x WHERE x.from_member_id = m.id AND x.to_member_id = @me AND x.read_at IS NULL) AS unread
      FROM members m JOIN users u ON u.id = m.user_id
      WHERE m.company_id = @c AND m.active AND m.id <> @me
        AND (@isManager OR m.role <> 'employee'
             OR EXISTS (SELECT 1 FROM messages x WHERE x.from_member_id = m.id AND x.to_member_id = @me))
      ORDER BY last_at DESC NULLS LAST, u.name''',
      {'c': ctx.companyId, 'me': ctx.memberId, 'isManager': ctx.isManager},
    );
    return jsonResponse([
      for (final r in rows)
        {
          'member_id': r['member_id'],
          'name': r['name'],
          'photo_url': r['photo_url'],
          'role': r['role'],
          'last_message': r['last_message'],
          'last_at': r['last_at'],
          'unread': r['unread'],
        },
    ]);
  }

  Future<void> _checkPeer(String companyId, String peerId, bool isManager) async {
    final peer = await app.db.one('SELECT role FROM members WHERE id = @id AND company_id = @c AND active',
        {'id': requireUuid(peerId), 'c': companyId});
    if (peer == null) throw const ApiError.notFound('Contato não encontrado');
    if (!isManager && peer['role'] == 'employee') {
      throw const ApiError.forbidden('O chat é entre colaboradores e gestores');
    }
  }

  Future<Response> _messages(Request req, String memberId) async {
    final ctx = await app.sessions.member(req);
    await _checkPeer(ctx.companyId, memberId, ctx.isManager);
    final after = req.q('after') == null ? null : DateTime.tryParse(req.q('after')!);
    final before = req.q('before') == null ? null : DateTime.tryParse(req.q('before')!);
    final wait = req.qInt('wait', 0).clamp(0, 25);

    Future<List<Map<String, dynamic>>> load() => app.db.query(
          '''
          $_messageSelect
          WHERE msg.company_id = @c
            AND ((msg.from_member_id = @me AND msg.to_member_id = @peer) OR (msg.from_member_id = @peer AND msg.to_member_id = @me))
            AND (@after::timestamptz IS NULL OR msg.created_at > @after::timestamptz)
            AND (@before::timestamptz IS NULL OR msg.created_at < @before::timestamptz)
          ORDER BY msg.created_at DESC LIMIT 100''',
          {'c': ctx.companyId, 'me': ctx.memberId, 'peer': memberId, 'after': after, 'before': before},
        );

    var rows = await load();
    // Long-polling: aguarda novas mensagens.
    if (rows.isEmpty && after != null && wait > 0) {
      await app.events.wait('member:${ctx.memberId}', Duration(seconds: wait));
      rows = await load();
    }
    return jsonResponse([for (final r in rows.reversed) map.message(r)]);
  }

  Future<Response> _send(Request req, String memberId) async {
    final ctx = await app.sessions.member(req);
    await _checkPeer(ctx.companyId, memberId, ctx.isManager);
    final body = await readJson(req);
    final text = body.optStr('body') ?? '';
    final attachment = optUuid(body.optStr('attachment_file_id'), 'attachment_file_id');
    if (text.isEmpty && attachment == null) throw const ApiError.badRequest('Mensagem vazia');
    if (text.length > 4000) throw const ApiError.badRequest('Mensagem muito longa');
    final row = await app.db.one(
      'INSERT INTO messages (company_id, from_member_id, to_member_id, body, attachment_file_id) '
      'VALUES (@c, @from, @to, @b, @att) RETURNING id',
      {'c': ctx.companyId, 'from': ctx.memberId, 'to': memberId, 'b': text, 'att': attachment},
    );
    app.events.publish('member:$memberId', 'message');
    final full = await app.db.one('$_messageSelect WHERE msg.id = @id', {'id': row!['id']});
    return created(map.message(full!));
  }

  Future<Response> _markRead(Request req, String memberId) async {
    final ctx = await app.sessions.member(req);
    final n = await app.db.execute(
      'UPDATE messages SET read_at = now() WHERE to_member_id = @me AND from_member_id = @peer AND read_at IS NULL',
      {'me': ctx.memberId, 'peer': requireUuid(memberId)},
    );
    return jsonResponse({'updated': n});
  }

  /// Long-polling genérico: retorna quando houver nova mensagem/notificação.
  Future<Response> _wait(Request req) async {
    final ctx = await app.sessions.member(req);
    final timeout = req.qInt('timeout', 25).clamp(1, 25);
    final event = await app.events.wait('member:${ctx.memberId}', Duration(seconds: timeout));
    return jsonResponse({'event': event});
  }

  // ---------------------------------------------------------------------------
  // Bloco de notas
  // ---------------------------------------------------------------------------

  Future<Response> _listNotes(Request req) async {
    final ctx = await app.sessions.member(req);
    final rows = await app.db.query(
        'SELECT * FROM notes WHERE member_id = @m ORDER BY pinned DESC, updated_at DESC', {'m': ctx.memberId});
    return jsonResponse([for (final r in rows) map.note(r)]);
  }

  Future<Response> _createNote(Request req) async {
    final ctx = await app.sessions.member(req);
    final body = await readJson(req);
    final title = body.optStr('title') ?? '';
    final text = body.optStr('body') ?? '';
    if (title.isEmpty && text.isEmpty) throw const ApiError.badRequest('Nota vazia');
    final row = await app.db.one(
      'INSERT INTO notes (member_id, title, body, pinned, color) VALUES (@m, @t, @b, @p, @c) RETURNING *',
      {'m': ctx.memberId, 't': title, 'b': text, 'p': body.optBool('pinned') ?? false, 'c': body.optStr('color') ?? 'default'},
    );
    return created(map.note(row!));
  }

  Future<Response> _updateNote(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    final body = await readJson(req);
    final row = await app.db.one(
      '''
      UPDATE notes SET title = COALESCE(@t, title), body = COALESCE(@b, body), pinned = COALESCE(@p, pinned),
        color = COALESCE(@c, color), updated_at = now()
      WHERE id = @id AND member_id = @m RETURNING *''',
      {
        'id': requireUuid(id),
        'm': ctx.memberId,
        't': body.containsKey('title') ? (body['title']?.toString() ?? '') : null,
        'b': body.containsKey('body') ? (body['body']?.toString() ?? '') : null,
        'p': body.optBool('pinned'),
        'c': body.optStr('color'),
      },
    );
    if (row == null) throw const ApiError.notFound('Nota não encontrada');
    return jsonResponse(map.note(row));
  }

  Future<Response> _deleteNote(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    final n = await app.db.execute('DELETE FROM notes WHERE id = @id AND member_id = @m', {'id': requireUuid(id), 'm': ctx.memberId});
    if (n == 0) throw const ApiError.notFound('Nota não encontrada');
    return noContent();
  }

  // ---------------------------------------------------------------------------
  // Notificações
  // ---------------------------------------------------------------------------

  Future<Response> _notifications(Request req) async {
    final ctx = await app.sessions.member(req);
    final rows = await app.db.query(
      'SELECT * FROM notifications WHERE member_id = @m AND (@unread = false OR read_at IS NULL) ORDER BY created_at DESC LIMIT 100',
      {'m': ctx.memberId, 'unread': req.q('unread') == 'true'},
    );
    return jsonResponse([for (final r in rows) map.notification(r)]);
  }

  Future<Response> _readAll(Request req) async {
    final ctx = await app.sessions.member(req);
    await app.db.execute('UPDATE notifications SET read_at = now() WHERE member_id = @m AND read_at IS NULL', {'m': ctx.memberId});
    return jsonResponse({'ok': true});
  }

  Future<Response> _readOne(Request req, String id) async {
    final ctx = await app.sessions.member(req);
    await app.db.execute('UPDATE notifications SET read_at = now() WHERE id = @id AND member_id = @m',
        {'id': requireUuid(id), 'm': ctx.memberId});
    return jsonResponse({'ok': true});
  }

  // ---------------------------------------------------------------------------
  // Arquivos
  // ---------------------------------------------------------------------------

  /// Upload binário: corpo = bytes, `Content-Type` = tipo, `X-Filename` = nome.
  Future<Response> _upload(Request req) async {
    final ctx = await app.sessions.member(req);
    final bytes = <int>[];
    await for (final chunk in req.read()) {
      bytes.addAll(chunk);
      if (bytes.length > 10 * 1024 * 1024) throw const ApiError.badRequest('Arquivo maior que 10 MB');
    }
    final row = await app.storage.save(
      bytes: bytes,
      contentType: req.headers['content-type'] ?? 'application/octet-stream',
      filename: Uri.decodeComponent(req.headers['x-filename'] ?? 'arquivo'),
      companyId: ctx.companyId,
      userId: ctx.user.id,
    );
    return created({
      'id': row['id'],
      'url': app.storage.signedUrl(row['id'] as String),
      'content_type': row['content_type'],
      'size': row['size'],
      'filename': row['filename'],
    });
  }

  Future<Response> _download(Request req, String id) async {
    final signed = app.storage.verifySignature(id, req.q('exp'), req.q('sig'));
    if (!signed) {
      final ctx = await app.sessions.member(req);
      final f = await app.db.one('SELECT company_id FROM files WHERE id = @id', {'id': requireUuid(id)});
      if (f == null || f['company_id'] != ctx.companyId) throw const ApiError.notFound('Arquivo não encontrado');
    }
    final (row, bytes) = await app.storage.read(id);
    return Response.ok(bytes, headers: {
      'content-type': row['content_type'] as String,
      'cache-control': 'private, max-age=3600',
      'content-disposition': 'inline; filename="${(row['filename'] as String).replaceAll('"', '')}"',
    });
  }
}
