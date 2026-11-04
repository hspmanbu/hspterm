import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/transfer_rate.dart';

void main() {
  test(
    'acknowledged deltas estimate speed and stall without fabricated ETA',
    () {
      final rate = TransferRate();
      rate.sample(
        acknowledged: 1000,
        total: 5000,
        running: true,
        elapsed: Duration.zero,
      );
      expect(rate.bytesPerSecond, isNull);
      rate.sample(
        acknowledged: 2000,
        total: 5000,
        running: true,
        elapsed: const Duration(milliseconds: 500),
      );
      expect(rate.bytesPerSecond, 2000);
      expect(rate.remainingSeconds, 2);
      rate.sample(
        acknowledged: 2000,
        total: 5000,
        running: true,
        elapsed: const Duration(seconds: 1),
      );
      expect(rate.bytesPerSecond, 0);
      expect(rate.remainingSeconds, isNull);
      rate.sample(
        acknowledged: 2500,
        total: null,
        running: true,
        elapsed: const Duration(milliseconds: 1500),
      );
      expect(rate.bytesPerSecond, 1000);
      expect(rate.remainingSeconds, isNull);
    },
  );
  test(
    'pause/resume and counter reset never charge old bytes to a new sample',
    () {
      final rate = TransferRate();
      rate.sample(
        acknowledged: 8000000,
        total: 10000000,
        running: true,
        elapsed: Duration.zero,
      );
      rate.sample(
        acknowledged: 8001000,
        total: 10000000,
        running: false,
        elapsed: const Duration(seconds: 1),
      );
      expect(rate.bytesPerSecond, isNull);
      rate.sample(
        acknowledged: 8001000,
        total: 10000000,
        running: true,
        elapsed: const Duration(seconds: 10),
      );
      expect(rate.bytesPerSecond, isNull);
      rate.sample(
        acknowledged: 8002000,
        total: 10000000,
        running: true,
        elapsed: const Duration(seconds: 11),
      );
      expect(rate.bytesPerSecond, 1000);
      rate.sample(
        acknowledged: 0,
        total: 10000000,
        running: true,
        elapsed: const Duration(seconds: 12),
      );
      expect(rate.bytesPerSecond, isNull);
    },
  );
}
