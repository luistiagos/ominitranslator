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
  File(path).writeAsBytesSync([...header.buffer.asUint8List(), ...int16.buffer.asUint8List()]);
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
