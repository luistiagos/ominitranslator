import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dubbing_engine/dubbing_engine.dart';
import '../state/app_state.dart';

const _stageNames = {
  PipelineStage.prepare: 'Preparando',
  PipelineStage.download: 'Baixando vídeo',
  PipelineStage.demux: 'Extraindo áudio',
  PipelineStage.separate: 'Separando voz da trilha',
  PipelineStage.diarize: 'Detectando falantes',
  PipelineStage.transcribe: 'Transcrevendo',
  PipelineStage.segment: 'Segmentando',
  PipelineStage.translate: 'Traduzindo',
  PipelineStage.synthesize: 'Sintetizando vozes',
  PipelineStage.fit: 'Ajustando tempo',
  PipelineStage.mix: 'Mixando',
  PipelineStage.mux: 'Gerando vídeo',
};

enum _StageStatus { pending, active, done, failed }

class ProgressScreen extends StatelessWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final events = state.jobEvents;
    final error = state.jobError;
    final result = state.jobResult;
    final running = state.jobRunning;

    _StageStatus _status(PipelineStage stage) {
      if (error != null) {
        final lastActive = _lastActiveStage(events);
        if (stage == lastActive) return _StageStatus.failed;
        if (events.any((e) => e.stage == stage && e.progress >= 1.0)) {
          return _StageStatus.done;
        }
        return _StageStatus.pending;
      }
      if (events.any((e) => e.stage == stage && e.progress >= 1.0)) {
        return _StageStatus.done;
      }
      if (events.any((e) => e.stage == stage)) {
        return _StageStatus.active;
      }
      return _StageStatus.pending;
    }

    double _progress(PipelineStage stage) {
      final stageEvents = events.where((e) => e.stage == stage);
      if (stageEvents.isEmpty) return 0.0;
      return stageEvents.last.progress;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Progresso')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final stage in PipelineStage.values) ...[
            ListTile(
              leading: _buildIcon(_status(stage), _progress(stage)),
              title: Text(_stageNames[stage]!),
              subtitle: _status(stage) == _StageStatus.active
                  ? LinearProgressIndicator(value: _progress(stage))
                  : null,
            ),
            if (_status(stage) == _StageStatus.active)
              Padding(
                padding: const EdgeInsets.only(left: 72, bottom: 8),
                child: Text(
                  '${(_progress(stage) * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
          const Divider(),
          for (final e in events.where((e) => e.isWarning))
            _warningBanner(context, e.message),
          if (result != null && result.voiceOverMode)
            _warningBanner(
              context,
              'A separação de voz falhou — o áudio original permaneceu '
              'audível sob a dublagem (voice-over).',
            ),
          ExpansionTile(
            title: const Text('Log'),
            subtitle: Text('${events.length} eventos'),
            children: [
              for (final e in events)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  child: Text(
                    '[${_stageNames[e.stage]}] ${e.message}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (running)
            ElevatedButton(
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Cancelar'),
                    content: const Text('Deseja cancelar o processo?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Não')),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          state.cancelJob();
                        },
                        child: const Text('Sim'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('Cancelar'),
            ),
          if (result != null) ...[
            Text('Arquivo gerado: ${result.outputVideo}'),
            if (result.originalVideo != null)
              Text('Vídeo original salvo em: ${result.originalVideo}'),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () => Process.run('explorer', ['/select,', result.outputVideo]),
              icon: const Icon(Icons.folder_open),
              label: const Text('Abrir pasta'),
            ),
          ],
          if (error != null) ...[
            Text('Erro: $error', style: const TextStyle(color: Colors.red)),
            if (state.currentJob != null)
              Text('Diretório de trabalho: ${state.currentJob!.workDir}'),
          ],
        ],
      ),
    );
  }

  Widget _warningBanner(BuildContext context, String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.15),
          border: Border.all(color: Colors.amber),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.amber),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIcon(_StageStatus status, double progress) {
    return switch (status) {
      _StageStatus.pending => const Icon(Icons.radio_button_unchecked, color: Colors.grey),
      _StageStatus.active => const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      _StageStatus.done => const Icon(Icons.check_circle, color: Colors.green),
      _StageStatus.failed => const Icon(Icons.cancel, color: Colors.red),
    };
  }

  PipelineStage? _lastActiveStage(List<PipelineEvent> events) {
    if (events.isEmpty) return null;
    return events.last.stage;
  }
}
