import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/file_service.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

/// Exibe o Comprovante de Registro de Ponto do Trabalhador.
Future<void> showReceiptSheet(
  BuildContext context,
  Map<String, dynamic> receipt, {
  required String punchId,
}) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => _ReceiptSheet(receipt: receipt, punchId: punchId),
  );
}

Future<void> showReceiptById(BuildContext context, String punchId) async {
  final api = ProviderScope.containerOf(context).read(apiProvider);
  final r = await runAction(
    context,
    () => api.getMap('/punches/$punchId/receipt'),
  );
  if (r != null && context.mounted) {
    await showReceiptSheet(context, r, punchId: punchId);
  }
}

class _ReceiptSheet extends ConsumerWidget {
  final Map<String, dynamic> receipt;
  final String punchId;
  const _ReceiptSheet({required this.receipt, required this.punchId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fields = [
      for (final f in receipt['fields'] as List)
        (f as Map).cast<String, dynamic>(),
    ];
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (c, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          children: [
            const Row(
              children: [
                Icon(Icons.verified, color: AppColors.accent, size: 28),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Ponto registrado!',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              receipt['title'] as String? ??
                  'Comprovante de Registro de Ponto do Trabalhador',
              style: const TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final f in fields)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              f['label'] as String,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.muted,
                              ),
                            ),
                            SelectableText(
                              f['value'] as String,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize:
                                    (f['label'] as String).startsWith('Código')
                                    ? 11
                                    : 15,
                                fontFamily:
                                    (f['label'] as String).startsWith('Código')
                                    ? 'monospace'
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    Center(
                      child: QrImageView(
                        data: 'NSR:${receipt['nsr']};HASH:${receipt['hash']}',
                        size: 120,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: receipt['text'] as String? ?? ''),
                      );
                      showSnack(context, 'Comprovante copiado');
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copiar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => runAction(context, () async {
                      final (bytes, name) = await ref
                          .read(apiProvider)
                          .download('/punches/$punchId/receipt.pdf');
                      await saveAndOpen(
                        bytes,
                        name ?? 'comprovante.pdf',
                        'application/pdf',
                      );
                    }),
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: const Text('PDF'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
