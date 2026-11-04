import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/run_log.dart';

void main() {
  test('current run log omits error secrets and foreign stack paths', () {
    final log = AppRunLog(clock: () => DateTime.utc(2026, 11, 5));
    log.event(
      AppLogEvent.operationFailed,
      error: StateError('synthetic-password /private/fixture'),
      stack: StackTrace.fromString(
        '#0 f (package:hspterm/workbench/model.dart:10:2)\n#1 /private/fixture.dart:20:3',
      ),
    );
    final out = log.export('1793836800000 +2ms [INFO] core: stateConnected');
    expect(out, contains('operationFailed'));
    expect(out, contains('model.dart:10:2'));
    expect(out, contains('stateConnected'));
    expect(out, isNot(contains('synthetic-password')));
    expect(out, isNot(contains('/private/fixture')));
    expect(AppRunLog().export(''), isNot(contains('operationFailed')));
    log.clear();
    expect(log.export(''), isNot(contains('operationFailed')));
  });
  test('current run UI log has a fixed memory budget', () {
    final log = AppRunLog();
    for (var i = 0; i < 35000; i++) {
      log.event(AppLogEvent.pageChanged, count: i);
    }
    expect(log.dropped, greaterThan(0));
    expect(log.export('').length, lessThan(AppRunLog.budget + 1024));
  });
}
