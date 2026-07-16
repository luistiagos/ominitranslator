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
}
