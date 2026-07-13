import 'dart:io';
import 'dart:typed_data';

class WavData {
  final Float32List samples;
  final int sampleRate;
  final int channels;
  WavData(this.samples, this.sampleRate, this.channels);
  Duration get duration =>
      Duration(microseconds: (samples.length ~/ channels * 1000000 ~/ sampleRate));
}

/// Duração em segundos lendo apenas os headers RIFF, sem carregar o payload.
double wavDurationSeconds(String path) {
  final file = File(path).openSync();
  try {
    final riff = file.readSync(12);
    if (riff.length < 12) throw FormatException('WAV truncado: $path');
    int channels = 0, sampleRate = 0, bitsPerSample = 0;
    final fileLength = file.lengthSync();
    int offset = 12;
    while (offset + 8 <= fileLength) {
      file.setPositionSync(offset);
      final header = file.readSync(8);
      if (header.length < 8) break;
      final chunkId = String.fromCharCodes(header.sublist(0, 4));
      final chunkSize = ByteData.sublistView(header).getUint32(4, Endian.little);
      if (chunkId == 'fmt ') {
        final fmt = file.readSync(16);
        final view = ByteData.sublistView(fmt);
        channels = view.getUint16(2, Endian.little);
        sampleRate = view.getUint32(4, Endian.little);
        bitsPerSample = view.getUint16(14, Endian.little);
      } else if (chunkId == 'data') {
        if (channels == 0 || sampleRate == 0 || bitsPerSample == 0) {
          throw FormatException('Chunk fmt ausente ou inválido em $path');
        }
        final bytesPerFrame = channels * (bitsPerSample ~/ 8);
        return chunkSize / (sampleRate * bytesPerFrame);
      }
      offset += 8 + chunkSize;
      if (chunkSize % 2 != 0) offset++;
    }
    throw FormatException('No data chunk found in WAV');
  } finally {
    file.closeSync();
  }
}

WavData readWav(String path) {
  final bytes = File(path).readAsBytesSync();
  final view = ByteData.sublistView(bytes);
  int offset = 12;
  int format = 0, channels = 0, sampleRate = 0, bitsPerSample = 0;
  int dataOffset = 0, dataSize = 0;
  while (offset + 8 <= bytes.length) {
    final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final chunkSize = view.getUint32(offset + 4, Endian.little);
    if (chunkId == 'fmt ') {
      format = view.getUint16(offset + 8, Endian.little);
      channels = view.getUint16(offset + 10, Endian.little);
      sampleRate = view.getUint32(offset + 12, Endian.little);
      bitsPerSample = view.getUint16(offset + 22, Endian.little);
    } else if (chunkId == 'data') {
      dataOffset = offset + 8;
      dataSize = chunkSize;
      break;
    }
    offset += 8 + chunkSize;
    if (chunkSize % 2 != 0) offset++;
  }
  if (dataOffset == 0) throw FormatException('No data chunk found in WAV');
  if (format == 1 && bitsPerSample != 16) {
    throw FormatException('Unsupported PCM bit depth: $bitsPerSample (expected 16)');
  }
  int bytesPerSample = bitsPerSample ~/ 8;
  int sampleCount = dataSize ~/ bytesPerSample;
  final samples = Float32List(sampleCount);
  if (format == 1) {
    for (int i = 0; i < sampleCount; i++) {
      samples[i] = view.getInt16(dataOffset + i * 2, Endian.little) / 32768.0;
    }
  } else if (format == 3) {
    for (int i = 0; i < sampleCount; i++) {
      samples[i] = view.getFloat32(dataOffset + i * 4, Endian.little);
    }
  } else {
    throw FormatException('Unsupported WAV format: $format');
  }
  return WavData(samples, sampleRate, channels);
}

void writeWavPcm16(String path, WavData data) {
  final int16 = Int16List(data.samples.length);
  for (int i = 0; i < data.samples.length; i++) {
    final clamped = data.samples[i].clamp(-1.0, 1.0);
    int16[i] = (clamped * 32767).round().clamp(-32768, 32767);
  }
  final dataSize = int16.length * 2;
  final header = ByteData(44);
  header.setUint32(0, 0x46464952, Endian.little);
  header.setUint32(4, 36 + dataSize, Endian.little);
  header.setUint32(8, 0x45564157, Endian.little);
  header.setUint32(12, 0x20746d66, Endian.little);
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, data.channels, Endian.little);
  header.setUint32(24, data.sampleRate, Endian.little);
  header.setUint32(28, data.sampleRate * data.channels * 2, Endian.little);
  header.setUint16(32, data.channels * 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  header.setUint32(36, 0x61746164, Endian.little);
  header.setUint32(40, dataSize, Endian.little);
  // Duas escritas diretas, sem `[...header, ...int16]`: o spread materializava
  // uma List<int> BOXED do arquivo inteiro (um objeto por amostra), muito pior
  // que o Int16List que já temos ao lado.
  final raf = File(path).openSync(mode: FileMode.write);
  try {
    raf.writeFromSync(header.buffer.asUint8List());
    raf.writeFromSync(int16.buffer.asUint8List());
  } finally {
    raf.closeSync();
  }
}

/// Cabeçalho de um WAV, lido sem tocar no payload.
typedef _WavHeader = ({
  int format,
  int channels,
  int sampleRate,
  int bitsPerSample,
  int dataOffset,
  int dataSize,
});

_WavHeader _readHeader(RandomAccessFile file, String path) {
  final fileLength = file.lengthSync();
  file.setPositionSync(0);
  final riff = file.readSync(12);
  if (riff.length < 12) throw FormatException('WAV truncado: $path');
  int format = 0, channels = 0, sampleRate = 0, bitsPerSample = 0;
  int offset = 12;
  while (offset + 8 <= fileLength) {
    file.setPositionSync(offset);
    final header = file.readSync(8);
    if (header.length < 8) break;
    final chunkId = String.fromCharCodes(header.sublist(0, 4));
    final chunkSize = ByteData.sublistView(header).getUint32(4, Endian.little);
    if (chunkId == 'fmt ') {
      final fmt = file.readSync(16);
      final view = ByteData.sublistView(fmt);
      format = view.getUint16(0, Endian.little);
      channels = view.getUint16(2, Endian.little);
      sampleRate = view.getUint32(4, Endian.little);
      bitsPerSample = view.getUint16(14, Endian.little);
    } else if (chunkId == 'data') {
      if (channels == 0 || sampleRate == 0 || bitsPerSample == 0) {
        throw FormatException('Chunk fmt ausente ou inválido em $path');
      }
      return (
        format: format,
        channels: channels,
        sampleRate: sampleRate,
        bitsPerSample: bitsPerSample,
        dataOffset: offset + 8,
        // Um WAV cujo header mente sobre o tamanho (processo morto no meio da
        // escrita) não pode fazer o leitor ler lixo além do fim do arquivo.
        dataSize: chunkSize > fileLength - (offset + 8)
            ? fileLength - (offset + 8)
            : chunkSize,
      );
    }
    offset += 8 + chunkSize;
    if (chunkSize % 2 != 0) offset++;
  }
  throw FormatException('No data chunk found in WAV: $path');
}

/// Leitura de um WAV por JANELA, sem carregar o arquivo inteiro.
///
/// O [readWav] materializa todo o payload num `Float32List` — o `asr_in.wav` de
/// um vídeo de uma hora são ~230 MB só nisso, e ele era lido duas vezes por job.
/// Aqui o arquivo fica aberto e só o intervalo pedido vira memória.
///
/// Feche com [close] (ou use dentro de um `try/finally`).
class WavReader {
  final String path;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  /// Quadros (não amostras): um quadro tem [channels] amostras.
  final int frameCount;

  final RandomAccessFile _file;
  final int _format;
  final int _dataOffset;
  final int _bytesPerFrame;
  bool _closed = false;

  WavReader._(this.path, this._file, _WavHeader h)
      : sampleRate = h.sampleRate,
        channels = h.channels,
        bitsPerSample = h.bitsPerSample,
        _format = h.format,
        _dataOffset = h.dataOffset,
        _bytesPerFrame = h.channels * (h.bitsPerSample ~/ 8),
        frameCount = h.dataSize ~/ (h.channels * (h.bitsPerSample ~/ 8));

  static WavReader open(String path) {
    final file = File(path).openSync();
    try {
      final h = _readHeader(file, path);
      if (h.format == 1 && h.bitsPerSample != 16) {
        throw FormatException(
            'Unsupported PCM bit depth: ${h.bitsPerSample} (expected 16)');
      }
      if (h.format != 1 && h.format != 3) {
        throw FormatException('Unsupported WAV format: ${h.format}');
      }
      return WavReader._(path, file, h);
    } catch (_) {
      file.closeSync();
      rethrow;
    }
  }

  double get durationSeconds => frameCount / sampleRate;

  /// Amostras intercaladas do intervalo pedido, normalizadas para [-1, 1].
  /// O intervalo é recortado ao que existe: pedir além do fim devolve menos.
  Float32List readFrames(int startFrame, int frames) {
    final bytes = readRawFrames(startFrame, frames);
    final view = ByteData.sublistView(bytes);
    final count = bytes.lengthInBytes ~/ (bitsPerSample ~/ 8);
    final out = Float32List(count);
    if (_format == 1) {
      for (int i = 0; i < count; i++) {
        out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
      }
    } else {
      for (int i = 0; i < count; i++) {
        out[i] = view.getFloat32(i * 4, Endian.little);
      }
    }
    return out;
  }

  /// Bytes crus do intervalo. Copiar PCM16 de um WAV para outro passa por aqui:
  /// sem conversão para float, sem perda e sem alocar o dobro.
  Uint8List readRawFrames(int startFrame, int frames) {
    if (_closed) throw StateError('WavReader já fechado: $path');
    if (startFrame < 0) startFrame = 0;
    if (startFrame >= frameCount || frames <= 0) return Uint8List(0);
    final available = frameCount - startFrame;
    final take = frames < available ? frames : available;
    _file.setPositionSync(_dataOffset + startFrame * _bytesPerFrame);
    return _file.readSync(take * _bytesPerFrame);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _file.closeSync();
  }
}

/// Escritor SEQUENCIAL de WAV PCM16.
///
/// A faixa dublada era montada num `Float32List` do vídeo inteiro (~635 MB por
/// hora, só em mono float32) e só então gravada. Aqui os quadros são escritos à
/// medida que saem, e o header é corrigido no fim — a memória não cresce com a
/// duração do vídeo.
///
/// Grava em `<path>.part` e só renomeia para `<path>` no [finish], para que um
/// arquivo truncado (processo morto no meio) nunca passe por completo.
class WavPcm16Writer {
  final String path;
  final int sampleRate;
  final int channels;

  final String _partPath;
  final RandomAccessFile _file;
  int _framesWritten = 0;
  bool _finished = false;

  WavPcm16Writer._(this.path, this._partPath, this._file, this.sampleRate,
      this.channels);

  static WavPcm16Writer create(String path,
      {required int sampleRate, int channels = 1}) {
    final partPath = '$path.part';
    final file = File(partPath).openSync(mode: FileMode.write);
    // Header provisório: os tamanhos só são conhecidos no fim.
    file.writeFromSync(_buildHeader(0, sampleRate, channels));
    return WavPcm16Writer._(path, partPath, file, sampleRate, channels);
  }

  int get framesWritten => _framesWritten;

  static Uint8List _buildHeader(int dataSize, int sampleRate, int channels) {
    final h = ByteData(44);
    h.setUint32(0, 0x46464952, Endian.little); // 'RIFF'
    h.setUint32(4, 36 + dataSize, Endian.little);
    h.setUint32(8, 0x45564157, Endian.little); // 'WAVE'
    h.setUint32(12, 0x20746d66, Endian.little); // 'fmt '
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little); // PCM
    h.setUint16(22, channels, Endian.little);
    h.setUint32(24, sampleRate, Endian.little);
    h.setUint32(28, sampleRate * channels * 2, Endian.little);
    h.setUint16(32, channels * 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    h.setUint32(36, 0x61746164, Endian.little); // 'data'
    h.setUint32(40, dataSize, Endian.little);
    return h.buffer.asUint8List();
  }

  /// Silêncio, em blocos — não aloca a lacuna inteira de uma vez.
  void writeSilence(int frames) {
    if (frames <= 0) return;
    const chunkFrames = 1 << 15;
    final bytesPerFrame = channels * 2;
    final chunk = Uint8List(chunkFrames * bytesPerFrame); // já é zero
    var left = frames;
    while (left > 0) {
      final take = left < chunkFrames ? left : chunkFrames;
      _file.writeFromSync(chunk, 0, take * bytesPerFrame);
      left -= take;
    }
    _framesWritten += frames;
  }

  /// Bytes PCM16 crus (cópia direta de outro WAV, sem passar por float).
  void writeRawFrames(Uint8List pcm16) {
    if (pcm16.isEmpty) return;
    _file.writeFromSync(pcm16);
    _framesWritten += pcm16.lengthInBytes ~/ (channels * 2);
  }

  /// Amostras float intercaladas, com clamp em [-1, 1].
  void writeFrames(Float32List samples) {
    if (samples.isEmpty) return;
    final int16 = Int16List(samples.length);
    for (int i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      int16[i] = (clamped * 32767).round().clamp(-32768, 32767);
    }
    _file.writeFromSync(int16.buffer.asUint8List());
    _framesWritten += samples.length ~/ channels;
  }

  /// Corrige os tamanhos do header, fecha e publica o arquivo.
  void finish() {
    if (_finished) return;
    _finished = true;
    try {
      final dataSize = _framesWritten * channels * 2;
      _file.setPositionSync(0);
      _file.writeFromSync(_buildHeader(dataSize, sampleRate, channels));
      _file.flushSync();
    } finally {
      _file.closeSync();
    }
    final target = File(path);
    if (target.existsSync()) target.deleteSync();
    File(_partPath).renameSync(path);
  }

  /// Aborta: fecha e remove o `.part`, sem publicar nada.
  void abort() {
    if (_finished) return;
    _finished = true;
    try {
      _file.closeSync();
    } catch (_) {}
    final part = File(_partPath);
    if (part.existsSync()) part.deleteSync();
  }
}

Float32List upsample2x(Float32List mono) {
  final result = Float32List(mono.length * 2);
  for (int i = 0; i < mono.length; i++) {
    result[i * 2] = mono[i];
    if (i < mono.length - 1) {
      result[i * 2 + 1] = (mono[i] + mono[i + 1]) / 2;
    } else {
      result[i * 2 + 1] = mono[i];
    }
  }
  return result;
}

Float32List stereoToMono(Float32List interleaved) {
  final count = interleaved.length ~/ 2;
  final result = Float32List(count);
  for (int i = 0; i < count; i++) {
    result[i] = (interleaved[i * 2] + interleaved[i * 2 + 1]) / 2;
  }
  return result;
}
