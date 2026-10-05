import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/file_service.dart';
import '../../state/data.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

const _template =
    'Nome;E-mail;CPF;Matrícula;Departamento;Cargo;Escala;Admissão;Telefone;Perfil;Crachá;PIN\n'
    'Maria da Silva;maria@empresa.com.br;529.982.247-25;101;Loja Centro;Atendente;;01/10/2026;(11) 99999-0000;colaborador;;1234\n';

/// Importação de colaboradores por planilha (CSV).
class ImportMembersPage extends ConsumerStatefulWidget {
  const ImportMembersPage({super.key});
  @override
  ConsumerState<ImportMembersPage> createState() => _ImportMembersPageState();
}

class _ImportMembersPageState extends ConsumerState<ImportMembersPage> {
  final _csv = TextEditingController();
  String? _fileName;
  Map<String, dynamic>? _result;
  bool _busy = false;

  Future<void> _pick() async {
    final f = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['csv', 'txt'],
    );
    if (f == null) return;
    final bytes = await f.xFile.readAsBytes();
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      // Planilhas do Excel em português costumam salvar em Windows-1252/Latin-1.
      text = latin1.decode(bytes);
    }
    setState(() {
      _csv.text = text;
      _fileName = f.name;
      _result = null;
    });
  }

  Future<void> _run({required bool dryRun}) async {
    if (_csv.text.trim().isEmpty) {
      showSnack(
        context,
        'Selecione um arquivo ou cole o conteúdo CSV',
        error: true,
      );
      return;
    }
    setState(() => _busy = true);
    final r = await runAction(
      context,
      () => ref.read(apiProvider).post('/members/import', {
        'csv': _csv.text,
        'dry_run': dryRun,
      }),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r != null) _result = (r as Map).cast();
    });
    if (!dryRun && r != null) {
      ref.invalidate(membersProvider);
      ref.invalidate(departmentsProvider);
      ref.invalidate(positionsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = [
      for (final r in (_result?['results'] as List? ?? const []))
        (r as Map).cast<String, dynamic>(),
    ];
    final passwords = results
        .where((r) => r['temporary_password'] != null)
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Importar colaboradores')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Constrained(
            maxWidth: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Como funciona',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '1. Baixe o modelo e preencha uma linha por colaborador (Nome, E-mail e CPF são obrigatórios).\n'
                          '2. Departamentos e cargos que não existirem serão criados; a escala deve ter o mesmo nome de uma escala cadastrada.\n'
                          '3. Valide antes de importar. Cada colaborador recebe o convite por e-mail com senha provisória.',
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => saveAndOpen(
                                Uint8List.fromList([
                                  0xEF,
                                  0xBB,
                                  0xBF,
                                  ...utf8.encode(_template),
                                ]),
                                'modelo-colaboradores.csv',
                                'text/csv',
                              ),
                              icon: const Icon(Icons.download_outlined),
                              label: const Text('Baixar modelo'),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: _pick,
                              icon: const Icon(Icons.upload_file),
                              label: Text(
                                _fileName ?? 'Selecionar arquivo CSV',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _csv,
                  minLines: 4,
                  maxLines: 10,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: 'Conteúdo CSV (ou cole aqui)',
                    alignLabelWithHint: true,
                  ),
                  onChanged: (_) => setState(() => _result = null),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _run(dryRun: true),
                        icon: const Icon(Icons.rule),
                        label: const Text('Validar'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : () => _run(dryRun: false),
                        icon: const Icon(Icons.group_add_outlined),
                        label: const Text('Importar'),
                      ),
                    ),
                  ],
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (_result != null) ...[
                  SectionTitle(
                    _result!['dry_run'] == true
                        ? 'Validação: ${results.length - (_result!['errors'] as int)} ok, ${_result!['errors']} com erro'
                        : '${_result!['created']} importado(s), ${_result!['errors']} com erro',
                    trailing: passwords.isEmpty
                        ? null
                        : TextButton.icon(
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(
                                  text: passwords
                                      .map(
                                        (p) =>
                                            '${p['name']};${p['email']};${p['temporary_password']}',
                                      )
                                      .join('\n'),
                                ),
                              );
                              showSnack(context, 'Senhas provisórias copiadas');
                            },
                            icon: const Icon(Icons.copy),
                            label: const Text('Copiar senhas'),
                          ),
                  ),
                  Card(
                    child: Column(
                      children: [
                        for (final r in results)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              r['ok'] == true
                                  ? Icons.check_circle
                                  : Icons.error_outline,
                              color: r['ok'] == true
                                  ? AppColors.accent
                                  : AppColors.danger,
                            ),
                            title: Text(
                              'Linha ${r['line']}: ${r['name'] ?? '—'}',
                            ),
                            subtitle: Text(
                              r['ok'] == true
                                  ? (r['temporary_password'] != null
                                        ? 'Senha provisória: ${r['temporary_password']}'
                                        : 'OK')
                                  : '${r['error']}',
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
