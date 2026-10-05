import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';
import '../../state/data.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

final apiKeysProvider = FutureProvider.autoDispose<List<J>>(
  (ref) => ref.watch(apiProvider).getList('/integrations/api-keys'),
);
final webhooksProvider = FutureProvider.autoDispose<List<J>>(
  (ref) => ref.watch(apiProvider).getList('/integrations/webhooks'),
);
final webhookEventsProvider = FutureProvider.autoDispose<List<J>>(
  (ref) => ref.watch(apiProvider).getList('/integrations/events'),
);

/// Chaves de API (folha, ERP, BI) e webhooks.
class IntegrationsPage extends ConsumerWidget {
  const IntegrationsPage({super.key});

  Future<void> _showSecret(
    BuildContext context,
    String title,
    String label,
    String value,
    String hint,
  ) => showDialog(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hint),
          const SizedBox(height: 12),
          Text(
            label,
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          SelectableText(
            value,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
          child: const Text('Copiar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Já guardei'),
        ),
      ],
    ),
  );

  Future<void> _newHook(BuildContext context, WidgetRef ref) async {
    final events = await ref.read(webhookEventsProvider.future);
    if (!context.mounted) return;
    final url = TextEditingController(text: 'https://');
    final selected = <String>{'punch.created'};
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Novo webhook'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: url,
                    decoration: const InputDecoration(
                      labelText: 'URL de destino (HTTPS)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final e in events)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: selected.contains(e['event']),
                      title: Text(e['label'] as String),
                      subtitle: Text(
                        e['event'] as String,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                      onChanged: (v) => set(
                        () => v == true
                            ? selected.add(e['event'] as String)
                            : selected.remove(e['event']),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Criar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final r = await runAction(
      context,
      () => ref.read(apiProvider).post('/integrations/webhooks', {
        'url': url.text.trim(),
        'events': selected.toList(),
      }),
    );
    ref.invalidate(webhooksProvider);
    if (r != null && context.mounted) {
      await _showSecret(
        context,
        'Webhook criado',
        'Segredo de assinatura',
        (r as Map)['secret'] as String,
        'Use este segredo para validar o cabeçalho X-PontoMax-Signature (HMAC-SHA256 do corpo). Ele não será exibido novamente.',
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final keys = ref.watch(apiKeysProvider);
    final hooks = ref.watch(webhooksProvider);
    final api = ref.read(apiProvider);
    if (!me.isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Integrações')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'Somente administradores',
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Integrações')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Constrained(
            maxWidth: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  color: AppColors.brand.withValues(alpha: 0.05),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'API do PontoMax',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Conecte sua folha de pagamento, ERP ou BI. As chaves de API são somente leitura: colaboradores, '
                          'marcações, espelhos, relatórios, AFD e AEJ. Envie no cabeçalho X-Api-Key.',
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          '${AppConfig.apiUrl}/punches?from=2026-10-01&to=2026-10-31',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SectionTitle(
                  'Chaves de API',
                  trailing: FilledButton.tonalIcon(
                    onPressed: () async {
                      final name = await promptText(
                        context,
                        'Nova chave de API',
                        label: 'Nome (ex.: Integração folha)',
                      );
                      if (name == null || !context.mounted) return;
                      final r = await runAction(
                        context,
                        () =>
                            api.post('/integrations/api-keys', {'name': name}),
                      );
                      ref.invalidate(apiKeysProvider);
                      if (r != null && context.mounted) {
                        await _showSecret(
                          context,
                          'Chave criada',
                          'Chave de API',
                          (r as Map)['key'] as String,
                          'Copie e guarde a chave em local seguro. Por segurança, ela não será exibida novamente.',
                        );
                      }
                    },
                    icon: const Icon(Icons.key_outlined),
                    label: const Text('Nova chave'),
                  ),
                ),
                AsyncView(
                  value: keys,
                  onRetry: () => ref.invalidate(apiKeysProvider),
                  builder: (list) => list.isEmpty
                      ? const Card(
                          child: ListTile(
                            leading: Icon(Icons.key_off_outlined),
                            title: Text('Nenhuma chave criada'),
                          ),
                        )
                      : Card(
                          child: Column(
                            children: [
                              for (final k in list)
                                ListTile(
                                  leading: Icon(
                                    Icons.key,
                                    color: k['revoked_at'] == null
                                        ? AppColors.accent
                                        : AppColors.muted,
                                  ),
                                  title: Text(k['name'] as String),
                                  subtitle: Text(
                                    [
                                      'pmx_${k['prefix']}_••••',
                                      if (k['created_by_name'] != null)
                                        'por ${k['created_by_name']}',
                                      k['last_used_at'] == null
                                          ? 'nunca usada'
                                          : 'usada ${relativeTime(DateTime.parse(k['last_used_at'] as String))}',
                                      if (k['revoked_at'] != null) 'revogada',
                                    ].join(' • '),
                                  ),
                                  trailing: k['revoked_at'] != null
                                      ? null
                                      : TextButton(
                                          onPressed: () async {
                                            if (!await confirm(
                                              context,
                                              'Revogar chave',
                                              'Integrações que usam "${k['name']}" deixarão de funcionar.',
                                              destructive: true,
                                              ok: 'Revogar',
                                            )) {
                                              return;
                                            }
                                            if (!context.mounted) return;
                                            await runAction(
                                              context,
                                              () => api.delete(
                                                '/integrations/api-keys/${k['id']}',
                                              ),
                                              success: 'Chave revogada',
                                            );
                                            ref.invalidate(apiKeysProvider);
                                          },
                                          child: const Text('Revogar'),
                                        ),
                                ),
                            ],
                          ),
                        ),
                ),
                SectionTitle(
                  'Webhooks',
                  trailing: FilledButton.tonalIcon(
                    onPressed: () => _newHook(context, ref),
                    icon: const Icon(Icons.webhook_outlined),
                    label: const Text('Novo webhook'),
                  ),
                ),
                AsyncView(
                  value: hooks,
                  onRetry: () => ref.invalidate(webhooksProvider),
                  builder: (list) => list.isEmpty
                      ? const Card(
                          child: ListTile(
                            leading: Icon(Icons.webhook_outlined),
                            title: Text('Nenhum webhook'),
                            subtitle: Text(
                              'Receba eventos em tempo real (marcações, solicitações, desligamentos...).',
                            ),
                          ),
                        )
                      : Card(
                          child: Column(
                            children: [
                              for (final h in list)
                                ListTile(
                                  leading: Icon(
                                    Icons.webhook,
                                    color: h['active'] != true
                                        ? AppColors.muted
                                        : (h['last_status'] == null ||
                                              (h['last_status'] as int) < 300 &&
                                                  (h['last_status'] as int) >=
                                                      200)
                                        ? AppColors.accent
                                        : AppColors.danger,
                                  ),
                                  title: Text(
                                    h['url'] as String,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    [
                                      (h['events'] as List).join(', '),
                                      if (h['last_status'] != null)
                                        'último envio: ${h['last_status'] == 0 ? 'falha de rede' : 'HTTP ${h['last_status']}'}',
                                      if (h['active'] != true) 'pausado',
                                    ].join(' • '),
                                  ),
                                  trailing: PopupMenuButton<String>(
                                    onSelected: (v) async {
                                      if (v == 'test') {
                                        final r = await runAction(
                                          context,
                                          () => api.post(
                                            '/integrations/webhooks/${h['id']}/test',
                                          ),
                                        );
                                        if (r != null && context.mounted) {
                                          showSnack(
                                            context,
                                            (r as Map)['ok'] == true
                                                ? 'Entregue com sucesso'
                                                : 'Falhou (status ${r['status']})',
                                            error: r['ok'] != true,
                                          );
                                        }
                                      } else if (v == 'toggle') {
                                        await runAction(
                                          context,
                                          () => api.put(
                                            '/integrations/webhooks/${h['id']}',
                                            {'active': h['active'] != true},
                                          ),
                                        );
                                      } else if (v == 'delete') {
                                        if (!await confirm(
                                          context,
                                          'Excluir webhook',
                                          h['url'] as String,
                                          destructive: true,
                                        )) {
                                          return;
                                        }
                                        if (!context.mounted) return;
                                        await runAction(
                                          context,
                                          () => api.delete(
                                            '/integrations/webhooks/${h['id']}',
                                          ),
                                        );
                                      }
                                      ref.invalidate(webhooksProvider);
                                    },
                                    itemBuilder: (_) => [
                                      const PopupMenuItem(
                                        value: 'test',
                                        child: Text('Enviar teste'),
                                      ),
                                      PopupMenuItem(
                                        value: 'toggle',
                                        child: Text(
                                          h['active'] == true
                                              ? 'Pausar'
                                              : 'Ativar',
                                        ),
                                      ),
                                      const PopupMenuItem(
                                        value: 'delete',
                                        child: Text('Excluir'),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
