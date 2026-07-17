import 'package:dubbing_engine/src/models.dart';
import 'package:test/test.dart';

void main() {
  group('DubbingJobConfig JSON (D3.3 — cruza o MethodChannel do foreground service)', () {
    DubbingJobConfig cfg({Lang src = Lang.en, Lang dst = Lang.pt}) =>
        DubbingJobConfig(
          inputVideo: '/sdcard/in.mp4',
          sourceLang: src,
          targetLang: dst,
          preset: Preset.fast,
          keepOriginalTrack: false,
          generateSrt: false,
          workDir: '/data/work/123',
          outputPath: '/sdcard/out.mp4',
          youtubeUrl: 'https://youtube.com/watch?v=x',
          ytDlpCookiesFromBrowser: 'chrome',
          speakerCount: 2,
          voiceModelId: 'piper-android-pt-br',
          voiceSid: 3,
        );

    test('ida e volta preserva todos os campos', () {
      final original = cfg();
      final back = DubbingJobConfig.fromJson(original.toJson());
      expect(back.inputVideo, original.inputVideo);
      expect(back.sourceLang, original.sourceLang);
      expect(back.targetLang, original.targetLang);
      expect(back.preset, original.preset);
      expect(back.keepOriginalTrack, original.keepOriginalTrack);
      expect(back.generateSrt, original.generateSrt);
      expect(back.workDir, original.workDir);
      expect(back.outputPath, original.outputPath);
      expect(back.youtubeUrl, original.youtubeUrl);
      expect(back.ytDlpCookiesFromBrowser, original.ytDlpCookiesFromBrowser);
      expect(back.ytDlpCookiesFile, original.ytDlpCookiesFile);
      expect(back.speakerCount, original.speakerCount);
      expect(back.voiceModelId, original.voiceModelId);
      expect(back.voiceSid, original.voiceSid);
    });

    test('campos opcionais nulos ida e volta como null, não crasham', () {
      final original = DubbingJobConfig(
        inputVideo: 'in.mp4',
        sourceLang: Lang.en,
        targetLang: Lang.es,
        preset: Preset.best,
        workDir: 'w',
        outputPath: 'o.mp4',
      );
      final back = DubbingJobConfig.fromJson(original.toJson());
      expect(back.youtubeUrl, isNull);
      expect(back.ytDlpCookiesFromBrowser, isNull);
      expect(back.ytDlpCookiesFile, isNull);
      expect(back.speakerCount, isNull);
      expect(back.voiceModelId, isNull);
      expect(back.voiceSid, 0);
    });

    test('islandês (isl) ida e volta corretamente pelo code, não pelo name', () {
      // 'is' é reservado em Dart, o identificador do enum é 'isl' mas
      // Lang.isl.code == 'is' — fromJson tem que buscar por code.
      final original = cfg(dst: Lang.isl);
      final json = original.toJson();
      expect(json['targetLang'], 'is');
      final back = DubbingJobConfig.fromJson(json);
      expect(back.targetLang, Lang.isl);
    });

    test('toJson serializa enums pelo valor estável (code/name), não pelo índice', () {
      final json = cfg().toJson();
      expect(json['sourceLang'], 'en');
      expect(json['targetLang'], 'pt');
      expect(json['preset'], 'fast');
    });
  });

  group('DubbingResult JSON (D3.4 — evento jobCompleted do foreground service)', () {
    DubbingResult result() => const DubbingResult(
          outputVideo: '/sdcard/out.mp4',
          srtSource: '/sdcard/out.en.srt',
          srtTarget: '/sdcard/out.pt.srt',
          originalVideo: '/sdcard/original.mp4',
          voiceOverMode: true,
          segmentsWithOverflow: 2,
          truncatedTail: Duration(milliseconds: 150),
          syncReport: '/sdcard/out.sync.json',
          elapsed: Duration(seconds: 42, milliseconds: 500),
        );

    test('ida e volta preserva todos os campos', () {
      final original = result();
      final back = DubbingResult.fromJson(original.toJson());
      expect(back.outputVideo, original.outputVideo);
      expect(back.srtSource, original.srtSource);
      expect(back.srtTarget, original.srtTarget);
      expect(back.originalVideo, original.originalVideo);
      expect(back.voiceOverMode, original.voiceOverMode);
      expect(back.segmentsWithOverflow, original.segmentsWithOverflow);
      expect(back.truncatedTail, original.truncatedTail);
      expect(back.syncReport, original.syncReport);
      expect(back.elapsed, original.elapsed);
    });

    test('campos opcionais nulos e Duration.zero ida e volta sem crashar', () {
      const original = DubbingResult(
        outputVideo: 'out.mp4',
        voiceOverMode: false,
        segmentsWithOverflow: 0,
        elapsed: Duration(seconds: 1),
      );
      final back = DubbingResult.fromJson(original.toJson());
      expect(back.srtSource, isNull);
      expect(back.srtTarget, isNull);
      expect(back.originalVideo, isNull);
      expect(back.syncReport, isNull);
      expect(back.truncatedTail, Duration.zero);
    });
  });
}
