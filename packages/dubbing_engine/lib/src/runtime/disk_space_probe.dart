import 'package:dubbing_engine/src/tools/disk_space.dart';

/// Espaço livre no volume que contém um path.
///
/// É assíncrono por causa do Android: lá o `StatFs` vem por MethodChannel, que
/// é async por natureza. No desktop a chamada é síncrona por baixo (FFI para o
/// `GetDiskFreeSpaceExW`), mas o contrato precisa ser o mesmo nas duas
/// plataformas — e a UI compartilhada não pode fazer I/O de disco dentro do
/// `build()`, que era o que acontecia com o `freeBytesForPath` síncrono.
abstract interface class DiskSpaceProbe {
  /// Bytes livres, ou null quando não há como saber (plataforma sem suporte
  /// ou falha da API do SO).
  Future<int?> freeBytes(String path);
}

/// Desktop: `GetDiskFreeSpaceExW`. Devolve null fora do Windows.
class WindowsDiskSpaceProbe implements DiskSpaceProbe {
  const WindowsDiskSpaceProbe();

  @override
  Future<int?> freeBytes(String path) async => freeBytesForPath(path);
}

/// Valor fixo — para testes e para plataformas que ainda não têm probe.
class FixedDiskSpaceProbe implements DiskSpaceProbe {
  final int? bytes;
  const FixedDiskSpaceProbe(this.bytes);

  @override
  Future<int?> freeBytes(String path) async => bytes;
}
