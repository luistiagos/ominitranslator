// Integration test for the full dubbing pipeline.
// Prerequisites:
//   - tools/win/ complete (ffmpeg, ffprobe, whisper-cli, translateLocally, sherpa-onnx)
//   - Models: whisper-base-q5_1, piper-en, piper-pt-br installed
//   - Translation models: en↔pt downloaded
// Run: dart run tool/integration_test.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:dubbing_engine/dubbing_engine.dart';
import 'package:dubbing_engine/src/backends/piper_synthesizer.dart';
import 'package:path/path.dart' as p;

int passed = 0;
int failed = 0;

void assertEq(String label, Object? expected, Object? actual) {
  if (expected == actual) {
    passed++;
    print('  PASS  $label');
  } else {
    failed++;
    print('  FAIL  $label: expected $expected, got $actual');
  }
}

void assertTrue(String label, bool value) {
  if (value) {
    passed++;
    print('  PASS  $label');
  } else {
    failed++;
    print('  FAIL  $label');
  }
}

void main() async {
  print('=== OmniTranslator Integration Test ===\n');

  // 0. Setup tools and models
  print('--- Step 0: Locate tools ---');
  Tools tools;
  try {
    tools = Tools.locate();
    print('  Tools found');
  } catch (e) {
    print('  FAIL: $e');
    print('\nPrerequisites not met. See comments at top of file.');
    exitCode = 1;
    return;
  }

  final appData = Platform.environment['APPDATA'] ?? '${Platform.environment['USERPROFILE']}\\AppData\\Roaming';
  final modelsRoot = '$appData\\omnitranslator\\models';
  final models = ModelManager(modelsRoot, tools);

  // Check required models
  final whisperOk = models.stateOf('whisper-base-q5_1') == ModelState.ready;
  final piperEnOk = models.stateOf('piper-en') == ModelState.ready;
  final piperPtOk = models.stateOf('piper-pt-br') == ModelState.ready;
  if (!whisperOk || !piperEnOk || !piperPtOk) {
    print('  Models missing: whisper-base-q5_1($whisperOk), piper-en($piperEnOk), piper-pt-br($piperPtOk)');
    print('\nPrerequisites not met. Download models first.');
    exitCode = 1;
    return;
  }
  print('  Models ready');

  // 1. Generate fixture
  print('\n--- Step 1: Generate fixture ---');
  final tempDir = Directory.systemTemp.path;
  final jobDir = '$tempDir\\omnitranslator_integration_test';
  if (Directory(jobDir).existsSync()) {
    Directory(jobDir).deleteSync(recursive: true);
  }
  Directory(jobDir).createSync(recursive: true);

  // Synthesize 5 sentences with Piper-en
  final synthesizer = PiperSynthesizer(Lang.en, models);
  final sentences = [
    'The weather is beautiful today.',
    'I would like a cup of coffee.',
    'The train leaves at seven in the morning.',
    'She bought three books yesterday.',
    'We are going to the beach this weekend.',
  ];
  final allSamples = <double>[];
  for (final sentence in sentences) {
    final audio = synthesizer.synthesize(sentence);
    allSamples.addAll(audio.samples);
    // 1 second silence between sentences
    allSamples.addAll(Float32List(audio.sampleRate * 1));
  }
  synthesizer.dispose();

  // Convert to mono PCM16 and write
  final speechPath = '$jobDir\\fixture_speech.wav';
  final speechSamples = Float32List(allSamples.length);
  for (int i = 0; i < allSamples.length; i++) {
    speechSamples[i] = allSamples[i];
  }
  final totalDur = speechSamples.length / 22050;
  writeWavPcm16(speechPath, WavData(speechSamples, 22050, 1));

  // Create video
  final fixtureVideo = '$jobDir\\fixture.mp4';
  final r = await runTool(tools.ffmpeg, [
    '-y',
    '-f', 'lavfi', '-i', 'color=c=blue:s=640x360:d=${totalDur + 2}',
    '-i', speechPath,
    '-c:v', 'libx264', '-preset', 'veryfast',
    '-c:a', 'aac',
    '-shortest',
    fixtureVideo,
  ]);
  if (r.exitCode != 0) {
    print('  FAIL: Could not generate fixture video: ${r.stderrTail}');
    exitCode = 1;
    return;
  }
  print('  Fixture video generated: $fixtureVideo');

  // 2. Run dubbing job
  print('\n--- Step 2: Run dubbing job (en→pt, fast) ---');
  final outputVideo = '$jobDir\\fixture_dub_pt.mp4';
  final config = DubbingJobConfig(
    inputVideo: fixtureVideo,
    sourceLang: Lang.en,
    targetLang: Lang.pt,
    preset: Preset.fast,
    keepOriginalTrack: true,
    generateSrt: true,
    workDir: '$jobDir\\work',
    outputPath: outputVideo,
  );

  final token = CancellationToken();
  PipelineException? jobError;

  try {
    await for (final event in runDubbingJob(config, token, tools: tools, models: models)) {
      print('  [${event.stage.name}] ${event.message}');
    }
  } on PipelineException catch (e) {
    jobError = e;
    print('  JOB FAILED: $e');
  }

  // 3. Assertions
  print('\n--- Step 3: Assertions ---');
  assertTrue('Job finished without exception', jobError == null);
  if (jobError != null) {
    failed++;
    print('  FAIL  Job error: $jobError');
    exitCode = 1;
    return;
  }

  assertTrue('Output file exists', File(outputVideo).existsSync());

  // Check streams
  final probe = await runTool(tools.ffprobe, [
    '-v', 'error',
    '-show_entries', 'stream=codec_type',
    '-of', 'csv',
    outputVideo,
  ]);
  final streamCounts = {'video': 0, 'audio': 0};
  for (final line in probe.stdout.trim().split('\n')) {
    if (line.contains('video')) streamCounts['video'] = streamCounts['video']! + 1;
    if (line.contains('audio')) streamCounts['audio'] = streamCounts['audio']! + 1;
  }
  assertEq('Video streams', 1, streamCounts['video']);
  assertEq('Audio streams', 2, streamCounts['audio']);

  // Check duration
  final durProbe = await runTool(tools.ffprobe, [
    '-v', 'error', '-show_entries', 'format=duration',
    '-of', 'default=noprint_wrappers=1:nokey=1',
    outputVideo,
  ]);
  final dur = double.parse(durProbe.stdout.trim());
  assertTrue('Duration matches fixture ±0.5s', (dur - totalDur).abs() < 0.5);

  // Check SRTs
  final baseName = p.basenameWithoutExtension(outputVideo);
  final outDir = p.dirname(outputVideo);
  final srtSource = '$outDir\\$baseName.en.srt';
  final srtTarget = '$outDir\\$baseName.pt.srt';
  assertTrue('Source SRT exists', File(srtSource).existsSync());
  assertTrue('Target SRT exists', File(srtTarget).existsSync());

  if (File(srtSource).existsSync()) {
    final srtContent = File(srtSource).readAsStringSync();
    final blocks = srtContent.trim().split('\n\n');
    assertTrue('Source SRT has >= 3 blocks', blocks.length >= 3);
  }
  if (File(srtTarget).existsSync()) {
    final srtContent = File(srtTarget).readAsStringSync();
    final blocks = srtContent.trim().split('\n\n');
    assertTrue('Target SRT has >= 3 blocks', blocks.length >= 3);
  }

  // 4. Summary
  print('\n=== Results: $passed passed, $failed failed ===');
  if (failed > 0) {
    print('FAILED: Some assertions failed');
    exitCode = 1;
  } else {
    print('ALL PASSED');
  }
}
