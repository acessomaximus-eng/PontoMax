import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pontomax_core/pontomax_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/api_client.dart';
import '../../config.dart';
import '../../services/photo_service.dart';
import '../../state/data.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

/// Work chat: lista de conversas.
class ConversationsPage extends ConsumerWidget {
  const ConversationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(conversationsProvider);
    final wide = isWide(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Work chat')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(conversationsProvider),
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(conversationsProvider),
          builder: (list) => list.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 80),
                    EmptyState(
                      icon: Icons.chat_bubble_outline,
                      title: 'Nenhum contato disponível',
                    ),
                  ],
                )
              : ListView.separated(
                  padding: EdgeInsets.symmetric(
                    horizontal: wide ? 24 : 8,
                    vertical: 8,
                  ),
                  itemCount: list.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (c, i) {
                    final conv = list[i];
                    return Constrained(
                      maxWidth: 800,
                      child: ListTile(
                        leading: Avatar(
                          name: conv.name,
                          url: conv.photoUrl,
                          radius: 24,
                        ),
                        title: Text(
                          conv.name,
                          style: TextStyle(
                            fontWeight: conv.unread > 0
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          conv.lastMessage ?? 'Iniciar conversa',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (conv.lastAt != null)
                              Text(
                                relativeTime(conv.lastAt!),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppColors.muted,
                                ),
                              ),
                            if (conv.unread > 0)
                              Badge(label: Text('${conv.unread}')),
                          ],
                        ),
                        onTap: () => context.push(
                          '/chat/${conv.memberId}?name=${Uri.encodeComponent(conv.name)}',
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

/// Conversa com long-polling para mensagens em tempo real.
class ChatPage extends ConsumerStatefulWidget {
  final String memberId;
  final String name;
  const ChatPage({super.key, required this.memberId, required this.name});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _messages = <ChatMessage>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _loading = true;
  bool _disposed = false;
  String? _error;

  ApiClient get _api => ref.read(apiProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await _api.getList('/chat/${widget.memberId}/messages');
      if (_disposed) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(list.map(ChatMessage.fromJson));
        _loading = false;
      });
      _markRead();
      _scrollToEnd();
      unawaited(_poll());
    } catch (e) {
      if (!_disposed) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _poll() async {
    while (!_disposed) {
      try {
        final after = _messages.isEmpty
            ? DateTime.now().toUtc()
            : _messages.last.createdAt;
        final list = await _api.get(
          '/chat/${widget.memberId}/messages',
          query: {'after': after.toIso8601String(), 'wait': 25},
          timeout: const Duration(seconds: 40),
        ) as List;
        if (_disposed) return;
        final fresh = list
            .map((e) => ChatMessage.fromJson((e as Map).cast()))
            .where((m) => !_messages.any((x) => x.id == m.id));
        if (fresh.isNotEmpty) {
          setState(() => _messages.addAll(fresh));
          _markRead();
          _scrollToEnd();
        }
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
  }

  void _markRead() {
    _api
        .post('/chat/${widget.memberId}/read')
        .then((_) {
          ref.invalidate(conversationsProvider);
          ref.read(sessionProvider.notifier).refreshMe().catchError((_) {});
        })
        .catchError((_) {});
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send({String? attachmentId}) async {
    final text = _input.text.trim();
    if (text.isEmpty && attachmentId == null) return;
    _input.clear();
    final r = await runAction(
      context,
      () => _api.post('/chat/${widget.memberId}/messages', {
        'body': text,
        'attachment_file_id': ?attachmentId,
      }),
    );
    if (r != null && mounted) {
      final m = ChatMessage.fromJson((r as Map).cast());
      if (!_messages.any((x) => x.id == m.id)) setState(() => _messages.add(m));
      _scrollToEnd();
    }
  }

  Future<void> _attach() async {
    final a = await PhotoService.attachment();
    if (a == null || !mounted) return;
    final up = await runAction(context, () => _api.upload(a.$1, a.$2, a.$3));
    if (up != null) await _send(attachmentId: up['id'] as String);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final myId = me.member?.id;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Avatar(name: widget.name, radius: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.name, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _error != null
                ? ErrorView(message: _error!, onRetry: _load)
                : _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                ? const EmptyState(
                    icon: Icons.waving_hand_outlined,
                    title: 'Diga olá!',
                    message: 'Envie a primeira mensagem.',
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (c, i) {
                      final m = _messages[i];
                      final mine = m.fromMemberId == myId;
                      return _Bubble(message: m, mine: mine, offset: me.offset);
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Anexar imagem',
                    onPressed: _attach,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Mensagem',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final bool mine;
  final int offset;
  const _Bubble({
    required this.message,
    required this.mine,
    required this.offset,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final wall = TimeFmt.toWall(message.createdAt, offset);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.75,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: mine
                ? t.colorScheme.primary
                : t.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(mine ? 16 : 4),
              bottomRight: Radius.circular(mine ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (message.attachmentUrl != null)
                GestureDetector(
                  onTap: () => launchUrl(
                    Uri.parse(AppConfig.resolveUrl(message.attachmentUrl)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      AppConfig.resolveUrl(message.attachmentUrl),
                      height: 180,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
              if (message.body.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    message.body,
                    style: TextStyle(
                      color: mine ? t.colorScheme.onPrimary : null,
                    ),
                  ),
                ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${LocalDate.fromDateTime(wall).toBr().substring(0, 5)} ${TimeFmt.clock(wall)}',
                    style: TextStyle(
                      fontSize: 10,
                      color: mine
                          ? t.colorScheme.onPrimary.withValues(alpha: 0.7)
                          : AppColors.muted,
                    ),
                  ),
                  if (mine) ...[
                    const SizedBox(width: 4),
                    Icon(
                      message.readAt != null ? Icons.done_all : Icons.done,
                      size: 14,
                      color: t.colorScheme.onPrimary.withValues(alpha: 0.8),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
