import 'dart:async';
import 'dart:math' as math;

/// Total de tentativas por padrão ao executar uma ferramenta externa ou
/// baixar um modelo: a execução original + 5 retries.
const int defaultMaxAttempts = 6;

/// Atraso exponencial entre tentativas (2s, 4s, 8s, 16s, 30s...), com teto
/// de 30s — dá tempo para picos de rede/rate limit (ex.: HTTP 429 do
/// YouTube) se dissiparem, sem deixar uma falha permanente demorar demais
/// a ser reportada.
Duration defaultRetryDelay(int attempt) {
  final seconds = math.min(30, 1 << attempt);
  return Duration(seconds: seconds);
}

/// Executa [attempt] até [maxAttempts] vezes. Para no primeiro resultado
/// aceito por [isSuccess]. Para também, sem mais tentativas, se [isFatal]
/// disser que aquele resultado não deve ser retentado (ex.: timeout) ou se
/// [isCancelled] indicar que o usuário cancelou a operação — nesses casos
/// devolve o último resultado obtido, não uma exceção. Aguarda
/// [retryDelay] entre tentativas.
Future<T> retryAsync<T>(
  Future<T> Function() attempt, {
  required bool Function(T result) isSuccess,
  bool Function(T result)? isFatal,
  bool Function()? isCancelled,
  int maxAttempts = defaultMaxAttempts,
  Duration Function(int attempt) retryDelay = defaultRetryDelay,
}) async {
  late T result;
  for (int i = 1; i <= maxAttempts; i++) {
    if (i > 1 && (isCancelled?.call() ?? false)) return result;
    result = await attempt();
    if (isSuccess(result)) return result;
    if ((isFatal?.call(result) ?? false) || (isCancelled?.call() ?? false)) {
      return result;
    }
    if (i < maxAttempts) {
      await _delayUnlessCancelled(retryDelay(i), isCancelled);
    }
  }
  return result;
}

/// Espera [duration], mas retorna cedo (em até ~200ms) se [isCancelled]
/// disser que o usuário cancelou — um backoff de 30s não pode segurar o
/// botão Cancelar por 30s.
Future<void> _delayUnlessCancelled(
    Duration duration, bool Function()? isCancelled) async {
  const step = Duration(milliseconds: 200);
  var remaining = duration;
  while (remaining > Duration.zero) {
    if (isCancelled?.call() ?? false) return;
    final wait = remaining < step ? remaining : step;
    await Future.delayed(wait);
    remaining -= wait;
  }
}
