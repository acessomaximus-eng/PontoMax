import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../theme.dart';

/// Leitor de QR Code. Retorna o conteúdo lido via `Navigator.pop`.
class QrScannerPage extends StatefulWidget {
  final String title;
  final String hint;
  const QrScannerPage({
    super.key,
    this.title = 'Ler QR Code',
    this.hint = 'Aponte a câmera para o QR Code exibido no quiosque',
  });

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final _manual = TextEditingController();
  bool _done = false;

  static bool get _cameraSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  void _finish(String value) {
    if (_done || value.trim().isEmpty) return;
    _done = true;
    Navigator.of(context).pop(value.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Expanded(
            child: _cameraSupported
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      MobileScanner(
                        onDetect: (capture) {
                          for (final b in capture.barcodes) {
                            final v = b.rawValue;
                            if (v != null) {
                              _finish(v);
                              break;
                            }
                          }
                        },
                        errorBuilder: (context, error) => Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'Câmera indisponível: ${error.errorCode.name}. Digite o código abaixo.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                      IgnorePointer(
                        child: Container(
                          width: 240,
                          height: 240,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: AppColors.accent,
                              width: 4,
                            ),
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 24,
                        left: 24,
                        right: 24,
                        child: Text(
                          widget.hint,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            shadows: [Shadow(blurRadius: 8)],
                          ),
                        ),
                      ),
                    ],
                  )
                : const Center(
                    child: Text(
                      'Leitura por câmera indisponível nesta plataforma.',
                    ),
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _manual,
                      decoration: const InputDecoration(
                        labelText: 'Ou digite/cole o código',
                        isDense: true,
                      ),
                      onSubmitted: _finish,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _finish(_manual.text),
                    child: const Text('OK'),
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
