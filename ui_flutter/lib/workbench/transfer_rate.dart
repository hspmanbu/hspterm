import 'dart:collection';

/// Three-second rolling estimate of confirmed content bytes. Samples are
/// bounded and throttled to 500ms; pause/resume never counts resumed bytes.
class TransferRate {
  final _samples = Queue<({int at, int bytes})>();
  static const _window = 3000000;
  double? bytesPerSecond;
  int? remainingSeconds;

  bool sample({
    required int acknowledged,
    required int? total,
    required bool running,
    required Duration elapsed,
  }) {
    final before = (bytesPerSecond, remainingSeconds);
    final now = elapsed.inMicroseconds;
    if (!running ||
        _samples.isEmpty ||
        now < _samples.last.at ||
        acknowledged < _samples.last.bytes) {
      _samples.clear();
      if (running) _samples.add((at: now, bytes: acknowledged));
      bytesPerSecond = null;
      remainingSeconds = null;
    } else if (now - _samples.last.at >= 500000) {
      _samples.add((at: now, bytes: acknowledged));
      final cutoff = now - _window;
      while (_samples.length > 2 && _samples.elementAt(1).at <= cutoff) {
        _samples.removeFirst();
      }
      final first = _samples.first;
      var start = first.at;
      double base = first.bytes.toDouble();
      if (start < cutoff) {
        final next = _samples.elementAt(1);
        base +=
            (next.bytes - first.bytes) * (cutoff - start) / (next.at - start);
        start = cutoff;
      }
      final speed = (acknowledged - base) * 1000000 / (now - start);
      bytesPerSecond = speed;
      remainingSeconds = total != null && speed > 0
          ? ((total - acknowledged).clamp(0, total) / speed).ceil()
          : null;
    }
    return before != (bytesPerSecond, remainingSeconds);
  }
}
