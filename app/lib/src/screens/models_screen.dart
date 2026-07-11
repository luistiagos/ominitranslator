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

  /// Baixa o modelo de tradução X→inglês (idiomas só-origem).
  Future<void> _downloadSourceModel(AppState appState, Lang from) async {
    final token = CancellationToken();
    try {
      await appState.modelManager.ensureTranslationModels(from, Lang.en, token);
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao baixar modelo de tradução: $e')),
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

  Widget _modelTile(AppState appState, ModelEntry entry, {bool isDefault = false}) {
    return Column(
      children: [
        ListTile(
          title: Row(
            children: [
              Flexible(child: Text(entry.displayName)),
              if (isDefault) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('padrão', style: TextStyle(fontSize: 11)),
                ),
              ],
            ],
          ),
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
    );
  }

  /// Vozes por idioma-alvo, na ordem de `Lang.values`, com a voz padrão
  /// (`piperModelId`) sempre listada primeiro.
  Map<Lang, List<ModelEntry>> _voicesByLang() {
    final byLang = <Lang, List<ModelEntry>>{};
    for (final entry in ModelManager.manifest) {
      if (entry.lang == null) continue;
      byLang.putIfAbsent(entry.lang!, () => []).add(entry);
    }
    for (final lang in byLang.keys) {
      final defaultId = piperModelId[lang];
      byLang[lang]!.sort((a, b) {
        if (a.id == defaultId) return -1;
        if (b.id == defaultId) return 1;
        return a.displayName.compareTo(b.displayName);
      });
    }
    return byLang;
  }

  Widget _voiceGroup(AppState appState, Lang lang, List<ModelEntry> entries) {
    final defaultId = piperModelId[lang];
    final installed = entries.where((e) => appState.modelStates[e.id] == ModelState.ready).length;
    return ExpansionTile(
      title: Text('Vozes — ${lang.label}'),
      subtitle: Text('$installed de ${entries.length} instaladas'),
      children: [
        for (final entry in entries) _modelTile(appState, entry, isDefault: entry.id == defaultId),
      ],
    );
  }

  /// Modelos de tradução X→inglês, deduplicados por id (alguns idiomas
  /// compartilham modelo, ex.: croata/sérvio/bósnio → hbs-eng-tiny).
  Map<String, List<Lang>> _sourceOnlyModelsById() {
    final byId = <String, List<Lang>>{};
    for (final lang in Lang.values) {
      if (lang == Lang.en || lang.isDubTarget) continue;
      final id = directTranslationModelId(lang, Lang.en);
      if (id == null) continue;
      byId.putIfAbsent(id, () => []).add(lang);
    }
    return byId;
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final essentials = ModelManager.manifest.where((e) => e.lang == null).toList();
    final voicesByLang = _voicesByLang();
    final dubTargets = Lang.values.where((l) => l.isDubTarget && voicesByLang.containsKey(l)).toList();
    final sourceOnlyModels = _sourceOnlyModelsById();

    return Scaffold(
      appBar: AppBar(title: const Text('Modelos')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Essenciais', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final entry in essentials) _modelTile(appState, entry),
          const SizedBox(height: 16),
          Text('Vozes de dublagem', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final lang in dubTargets) _voiceGroup(appState, lang, voicesByLang[lang]!),
          const SizedBox(height: 24),
          Text('Tradução', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('Pares de dublagem (idioma ↔ inglês)', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final lang in dubTargets)
                ElevatedButton(
                  onPressed: () => _downloadTranslationPair(appState, Lang.en, lang),
                  child: Text('Baixar en↔${lang.code}'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Idiomas só-origem (dublar A PARTIR deles, para inglês)',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in sourceOnlyModels.entries)
                ElevatedButton(
                  onPressed: () => _downloadSourceModel(appState, entry.value.first),
                  child: Text(
                      '${entry.value.map((l) => l.label).join('/')} → Inglês'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
