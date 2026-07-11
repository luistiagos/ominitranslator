import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

typedef _GetDiskFreeSpaceExNative = Int32 Function(
    Pointer<Utf16> lpDirectoryName,
    Pointer<Uint64> lpFreeBytesAvailable,
    Pointer<Uint64> lpTotalNumberOfBytes,
    Pointer<Uint64> lpTotalNumberOfFreeBytes);
typedef _GetDiskFreeSpaceEx = int Function(
    Pointer<Utf16> lpDirectoryName,
    Pointer<Uint64> lpFreeBytesAvailable,
    Pointer<Uint64> lpTotalNumberOfBytes,
    Pointer<Uint64> lpTotalNumberOfFreeBytes);

/// Bytes livres na unidade que contém [path]. Retorna null se não for
/// possível determinar (plataforma não suportada ou falha da API do SO).
int? freeBytesForPath(String path) {
  if (!Platform.isWindows) return null;
  final DynamicLibrary kernel32;
  try {
    kernel32 = DynamicLibrary.open('kernel32.dll');
  } catch (_) {
    return null;
  }
  final getDiskFreeSpaceEx = kernel32.lookupFunction<_GetDiskFreeSpaceExNative,
      _GetDiskFreeSpaceEx>('GetDiskFreeSpaceExW');
  final root = p.rootPrefix(p.absolute(path));
  final rootPtr = root.toNativeUtf16();
  final freeAvail = calloc<Uint64>();
  final total = calloc<Uint64>();
  final totalFree = calloc<Uint64>();
  try {
    final ok = getDiskFreeSpaceEx(rootPtr, freeAvail, total, totalFree);
    if (ok == 0) return null;
    return freeAvail.value;
  } finally {
    calloc.free(rootPtr);
    calloc.free(freeAvail);
    calloc.free(total);
    calloc.free(totalFree);
  }
}

/// Letra/prefixo da unidade que contém [path] (ex.: "C:\").
String driveOf(String path) => p.rootPrefix(p.absolute(path));
