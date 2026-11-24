import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/transfer_eta.dart';

void main() {
  test('ETA keeps seconds below a minute and formats boundaries', () {
    for (final entry in <int?, String>{
      null: '—',
      -1: '—',
      0: '约 0秒',
      59: '约 59秒',
      60: '约 1分0秒',
      3599: '约 59分59秒',
      3600: '约 1小时0分0秒',
      3723: '约 1小时2分3秒',
      90061: '约 25小时1分1秒',
    }.entries) {
      expect(transferEta(entry.key), entry.value);
    }
  });
}
