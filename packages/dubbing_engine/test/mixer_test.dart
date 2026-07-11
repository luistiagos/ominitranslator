import 'dart:io';
import 'dart:typed_data';
import 'package:dubbing_engine/src/steps/mixer.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/wav.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ToolResult _okResult() => ToolResult(0, '', '');
ToolResult _failResult() => ToolResult(1, '', 'error');

final _tools = Tools(
  ffmpeg: 'ffmpeg',
  ffprobe: 'ffprobe',
  whisperCli: 'whisper-cli',
  translateLocally: 'translateLocally',
  sherpaSourceSeparation: 'sherpa-separation',
);

void main() {
  group('buildDubTrack buffer', () {
    test('1 second buffer has expected sample count', () async {
      final segments = <DubbingSegment>[];
      final path = await buildDubTrack(segments, 1.0, Directory.systemTemp.path, CancellationToken());
      final wav = readWav(path);
      expect(wav.samples.length, 44100);
    });

    test('clamps overlapping samples at 1.0', () async {
      final seg = DubbingSegment(0, Duration.zero, Duration(milliseconds: 500), 'test');
      seg.fittedAudio = Float32List(22050);
      seg.fittedAudio!.fillRange(0, 22050, 0.7);
      final seg2 = DubbingSegment(1, Duration.zero, Duration(milliseconds: 500), 'test2');
      seg2.fittedAudio = Float32List(22050);
      seg2.fittedAudio!.fillRange(0, 22050, 0.5);

      final path = await buildDubTrack([seg, seg2], 1.0, Directory.systemTemp.path, CancellationToken());
      final wav = readWav(path);
      expect(wav.samples[0], closeTo(1.0, 0.001));
    });

    test('segment past end of buffer does not throw', () async {
      final seg = DubbingSegment(0, Duration(milliseconds: 900), Duration(milliseconds: 1100), 'test');
      seg.fittedAudio = Float32List(44100);

      await expectLater(
        () => buildDubTrack([seg], 1.0, Directory.systemTemp.path, CancellationToken()),
        returnsNormally,
      );
    });
  });

  group('buildFinalMix', () {
    test('voice-over mode succeeds', () async {
      final tempDir = Directory.systemTemp.createTempSync('mix_vo_');
      try {
        final dubbedPath = p.join(tempDir.path, 'dubbed.wav');
        File(dubbedPath).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));

        final result = await buildFinalMix(true, tempDir.path, _tools, CancellationToken(),
            runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _okResult());
        expect(result, dubbedPath);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('accompaniment mode succeeds', () async {
      final tempDir = Directory.systemTemp.createTempSync('mix_acc_');
      try {
        final dubbedPath = p.join(tempDir.path, 'dubbed.wav');
        File(dubbedPath).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'accompaniment.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));

        final result = await buildFinalMix(false, tempDir.path, _tools, CancellationToken(),
            runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _okResult());
        expect(result, dubbedPath);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('voice-over mode throws on ffmpeg failure', () async {
      final tempDir = Directory.systemTemp.createTempSync('mix_vo_fail_');
      try {
        File(p.join(tempDir.path, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));

        await expectLater(
          buildFinalMix(true, tempDir.path, _tools, CancellationToken(),
              runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _failResult()),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('accompaniment mode throws on ffmpeg failure', () async {
      final tempDir = Directory.systemTemp.createTempSync('mix_acc_fail_');
      try {
        File(p.join(tempDir.path, 'accompaniment.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));

        await expectLater(
          buildFinalMix(false, tempDir.path, _tools, CancellationToken(),
              runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _failResult()),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('throws when dubbed.wav is missing after ffmpeg', () async {
      final tempDir = Directory.systemTemp.createTempSync('mix_missing_');
      try {
        File(p.join(tempDir.path, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));

        await expectLater(
          buildFinalMix(true, tempDir.path, _tools, CancellationToken(),
              runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _okResult()),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
