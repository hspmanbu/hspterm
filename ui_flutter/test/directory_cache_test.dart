import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/directory_cache.dart';
import 'package:hspterm/workbench/directory_reader.dart';

void main() {
  test('metadata weight evicts old directories before the count ceiling', () {
    final files = <String, List<DemoFile>>{};
    final cache = DirectoryCache(files, maxEstimatedBytes: 100);
    final a = LoadedDirectory('/a', [DemoFile('/a/one', 'one')], 40);
    final b = LoadedDirectory('/b', [DemoFile('/b/two', 'two')], 40);
    final c = LoadedDirectory('/c', [DemoFile('/c/three', 'three')], 40);
    cache.store(a);
    cache.store(b);
    cache.store(a); // refresh moves A to the most recently used position
    cache.store(c);
    expect(files.keys, ['/a', '/c']);
    expect(identical(files['/a'], a.files), true);
    expect(cache.estimatedBytes, 80);
  });

  test('oversized current directory is complete and evicted after leaving', () {
    final files = <String, List<DemoFile>>{};
    final cache = DirectoryCache(files, maxEstimatedBytes: 100);
    cache.store(LoadedDirectory('/old', [], 20));
    final all = List.generate(4096, (i) => DemoFile('/large/$i', '$i'));
    cache.store(LoadedDirectory('/large', all, 200));
    expect(files.keys, ['/large']);
    expect(identical(files['/large'], all), true);
    expect(files['/large'], hasLength(4096));
    expect(cache.estimatedBytes, 200);
    cache.store(LoadedDirectory('/small', [], 20));
    expect(files.keys, ['/small']);
    expect(cache.estimatedBytes, 20);
  });

  test('refresh, invalidation and reconnect release weights with metadata', () {
    final files = <String, List<DemoFile>>{};
    final cache = DirectoryCache(
      files,
      maxDirectories: 2,
      maxEstimatedBytes: 1000,
    );
    cache.store(LoadedDirectory('/a', [], 40));
    cache.store(LoadedDirectory('/b', [], 30));
    cache.store(LoadedDirectory('/c', [], 20));
    expect(files.keys, ['/b', '/c']);
    expect(cache.estimatedBytes, 50);
    cache.store(LoadedDirectory('/b', [], 10));
    expect(cache.estimatedBytes, 30);
    cache.remove('/b');
    cache.remove('/b');
    expect(files.keys, ['/c']);
    expect(cache.estimatedBytes, 20);
    cache.clear();
    expect(files, isEmpty);
    expect(cache.estimatedBytes, 0);
    cache.store(LoadedDirectory('/new-server', [], 15));
    expect(cache.estimatedBytes, 15);
  });
}
