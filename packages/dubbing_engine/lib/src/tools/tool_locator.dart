import 'dart:io';
import 'package:path/path.dart' as p;

class Tools {
  final String ffmpeg;
  final String ffprobe;
  final String whisperCli;
  final String translateLocally;
  final String sherpaSourceSeparation;
  final String ytDlp;
  const Tools({
    required this.ffmpeg,
    required this.ffprobe,
    required this.whisperCli,
    required this.translateLocally,
    required this.sherpaSourceSeparation,
    this.ytDlp = '',
  });
  bool get hasYtDlp => ytDlp.isNotEmpty && File(ytDlp).existsSync();

  static Tools locate() {
    final envDir = Platform.environment['OMNITRANSLATOR_TOOLS_DIR'];
    String baseDir;
    if (envDir != null && envDir.isNotEmpty) {
      baseDir = envDir;
    } else {
      baseDir = _findToolsDir();
    }
    final missing = <String>[];
    String exe(String name, [String sub = '']) {
      final full = sub.isEmpty
          ? p.join(baseDir, '$name.exe')
          : p.join(baseDir, sub, '$name.exe');
      if (File(full).existsSync()) return full;
      missing.add(full);
      return full;
    }
    final ytPath = p.join(baseDir, 'yt-dlp.exe');
    final tools = Tools(
      ffmpeg: exe('ffmpeg'),
      ffprobe: exe('ffprobe'),
      whisperCli: exe('whisper-cli'),
      translateLocally: exe('translateLocally', 'translateLocally'),
      sherpaSourceSeparation: exe('sherpa-onnx-offline-source-separation', 'sherpa'),
      ytDlp: File(ytPath).existsSync() ? ytPath : '',
    );
    if (missing.isNotEmpty) {
      throw StateError('Missing tools: ${missing.join(', ')}');
    }
    return tools;
  }
  static String _findToolsDir() {
    List<String> candidates = [
      Directory.current.path,
      p.dirname(Platform.resolvedExecutable),
      Platform.script.toFilePath(),
    ];
    for (final c in candidates) {
      var dir = Directory(c);
      while (true) {
        final testPath = p.join(dir.path, 'tools', 'win');
        if (Directory(testPath).existsSync() &&
            File(p.join(testPath, 'ffmpeg.exe')).existsSync()) {
          return testPath;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    throw StateError('Could not locate tools/win directory. Set OMNITRANSLATOR_TOOLS_DIR env var or place tools under <repo>/tools/win/');
  }
}
