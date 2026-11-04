/// A display estimate from acknowledged-byte samples and a monotonic clock.
/// Never counts resumed bytes as newly transferred, and never invents an ETA
/// while scanning, paused, stalled, or when the total is unknown.
class TransferRate {
  int? _bytes, _at;
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
        _bytes == null ||
        _at == null ||
        now <= _at! ||
        acknowledged < _bytes!) {
      _bytes = running ? acknowledged : null;
      _at = running ? now : null;
      bytesPerSecond = null;
      remainingSeconds = null;
    } else if (now - _at! >= 500000) {
      final speed = (acknowledged - _bytes!) * 1000000 / (now - _at!);
      bytesPerSecond = speed;
      remainingSeconds = total != null && speed > 0
          ? ((total - acknowledged).clamp(0, total) / speed).ceil()
          : null;
      _bytes = acknowledged;
      _at = now;
    }
    return before != (bytesPerSecond, remainingSeconds);
  }
}
