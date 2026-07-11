import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dubbing_engine/dubbing_engine.dart';
import '../state/app_state.dart';

class ModelsScreen extends StatefulWidget {
  const ModelsScreen({super.key});

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  final Map<String, double> _downloadProgress = {};
  final Map<String, StreamSubscription<double>> _downloadSubscriptions = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().refreshModelStates();
    });
  }

  @override
  void dispose() {
    for (final sub in _downloadSubscriptions.values) {
      sub.cancel();
    }
    super.dispose();
  }

  /// Baixa os modelos de tradução nas duas direções (a↔b).
  Future<void> _downloadTranslationPair(AppState appState, Lang a, Lang b) async {
    final token = CancellationToken();
    try {
      await appState.modelManager.ensureTranslationModels(a, b, token);
      await appState.modelManager.ensureTranslationModels(b, a, token);
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao baixar modelos de tradução: $e')),
        );
      }
    }
    await appState.refreshModelStates();
  }

  String _stateLabel(ModelState state, String id) {
    if (_downloadProgress.containsKey(id)) {
      final pct = (_downloadProgress[id]! * 100).toStringAsFixed(0);
      return 'baixando $pct%';
    }
    return switch (state) {
      ModelState.missing => 'ausente',
      ModelState.downloading => 'incompleto — clique em Baixar para retomar',
      ModelState.ready => 'pronto',
      ModelState.corrupted => 'corrompido',
    };
  }

  Widget _actionButton(AppState appState, ModelEntry entry) {
    final state = appState.modelStates[entry.id];
    if (_downloadProgress.containsKey(entry.id)) {
      return TextButton(
        onPressed: () {
          _downloadSubscriptions[entry.id]?.cancel();
          setState(() {
            _downloadProgress.remove(entry.id);
            _downloadSubscriptions.remove(entry.id);
          });
        },
        child: const Text('Cancelar'),
      );
    }
    if (state == ModelState.ready) {
      return TextButton(
        onPressed: () async {
          await appState.modelManager.delete(entry.id);
          await appState.refreshModelStates();
        },
        child: const Text('Apagar'),
      );
    }
    return TextButton(
      onPressed: () {
        if (_downloadSubscriptions.containsKey(entry.id)) return;
        final stream = appState.modelManager.download(entry.id);
        final sub = stream.listen(
          (progress) => setState(() => _downloadProgress[entry.id] = progress),
          onDone: () async {
            await appState.refreshModelStates();
            setState(() {
              _downloadProgress.remove(entry.id);
              _downloadSubscriptions.remove(entry.id);
            });
          },
          onError: (Object e) async {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Falha ao baixar ${entry.displayName}: $e')),
              );
            }
            await appState.refreshModelStates();
            setState(() {
              _downloadProgress.remove(entry.id);
              _downloadSubscriptions.remove(entry.id);
            });
          },
        );
        setState(() {
          _downloadSubscriptions[entry.id] = sub;
          _downloadProgress[entry.id] = 0.0;
        });
      },
      child: const Text('Baixar'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final manifest = ModelManager.manifest;

    return Scaffold(
      appBar: AppBar(title: const Text('Modelos')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final entry in manifest) ...[
            ListTile(
              title: Text(entry.displayName),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${entry.sizeMb} MB'),
                  Text(_stateLabel(appState.modelStates[entry.id] ?? ModelState.missing, entry.id)),
                  if (_downloadProgress.containsKey(entry.id))
                    LinearProgressIndicator(value: _downloadProgress[entry.id]),
                ],
              ),
              trailing: _actionButton(appState, entry),
            ),
            const Divider(),
          ],
          const SizedBox(height: 24),
          Text('Tradução', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: () => _downloadTranslationPair(appState, Lang.en, Lang.pt),
            child: const Text('Baixar modelos en↔pt'),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: () => _downloadTranslationPair(appState, Lang.en, Lang.es),
            child: const Text('Baixar modelos en↔es'),
          ),
        ],
      ),
    );
  }
}
