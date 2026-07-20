import 'package:flutter/material.dart';

/// Tela "Sobre" — cobre os 7 itens do §16.3 da spec Android (sherpa-onnx/ONNX
/// Runtime, Whisper, Piper + vozes, slimt, modelos de tradução, FFmpegKit/
/// FFmpeg, pacotes Dart). Conteúdo estático (não vem do catálogo — `ModelEntry`
/// não tem campo de licença) e as licenças foram verificadas na fonte (não de
/// memória), mesma disciplina usada na investigação do GPL do slimt.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sobre')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('OmniTranslator', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          const Text('Dublagem automática de vídeos, on-device.'),
          const SizedBox(height: 24),
          Text('Componentes de terceiros', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const _Notice(
            name: 'sherpa-onnx e ONNX Runtime',
            license: 'Apache-2.0 (sherpa-onnx) / MIT (ONNX Runtime)',
            note: 'Motor de inferência para reconhecimento de fala (ASR), '
                'detecção de atividade de voz e síntese de fala.',
          ),
          const _Notice(
            name: 'Whisper (modelos de reconhecimento de fala)',
            license: 'MIT (OpenAI) — conversões ONNX distribuídas via sherpa-onnx (Apache-2.0)',
            note: 'Modelos "Rápido" (tiny) e "Melhor" (base).',
          ),
          const _Notice(
            name: 'Silero VAD',
            license: 'MIT',
            note: 'Detecção de segmentos de fala.',
          ),
          const _Notice(
            name: 'Piper (motor de síntese de voz)',
            license: 'MIT',
          ),
          const _Notice(
            name: 'Voz — Português (BR) (pt_BR-faber-medium)',
            license: 'CC0 (domínio público)',
          ),
          const _Notice(
            name: 'Voz — Espanhol (es_ES-sharvard-medium)',
            license: 'CC-BY 3.0',
            note: 'Requer atribuição ao autor original da voz.',
          ),
          const _Notice(
            name: 'Voz — Inglês (en_US-lessac-medium)',
            license: 'Licença do dataset Blizzard 2013 (Lessac) — uso restrito a pesquisa',
            note: 'Risco de licença conhecido e registrado (docs/decisoes.md, '
                '2026-07-19): o texto da licença original do dataset restringe '
                'uso a fins de pesquisa e não autoriza produtos comerciais de '
                'síntese de voz. Mantido nesta versão por decisão consciente; '
                'não omitido aqui de propósito.',
            warning: true,
          ),
          const _Notice(
            name: 'slimt (tradução automática)',
            license: 'GPLv2',
            note: 'Linkado in-process. Risco de licença conhecido e registrado '
                '(docs/decisoes.md, 2026-07-15/16/17); mantido nesta versão por '
                'decisão consciente.',
            warning: true,
          ),
          const _Notice(
            name: 'Modelos de tradução (Mozilla Firefox Translations)',
            license: 'MPL-2.0',
          ),
          const _Notice(
            name: 'FFmpegKitNext / FFmpeg',
            license: 'LGPL',
            note: 'Build próprio (sem --enable-gpl, arm64-v8a, API 28) — sem '
                'bibliotecas GPL no binário do FFmpeg.',
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'OmniTranslator',
            ),
            child: const Text('Licenças de bibliotecas (pacotes Dart/Flutter)'),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.name,
    required this.license,
    this.note,
    this.warning = false,
  });

  final String name;
  final String license;
  final String? note;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(license),
          if (note != null)
            Text(
              note!,
              style: TextStyle(
                fontSize: 12,
                color: warning ? Colors.red.shade700 : Colors.black54,
              ),
            ),
        ],
      ),
    );
  }
}
