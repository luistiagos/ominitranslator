import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

bool _initialized = false;

/// Inicializa os bindings nativos do sherpa-onnx uma única vez por isolate.
void ensureSherpaBindings() {
  if (_initialized) return;
  sherpa.initBindings();
  _initialized = true;
}
