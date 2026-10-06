import 'dart:convert';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/python_sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final source = 'py:${'a' * 32}';

  PythonSourceInfo script({bool enabled = true, String revision = '1'}) =>
      PythonSourceInfo.fromJson({
        'id': source,
        'name': '合成 Python 站源',
        'filename': 'synthetic.py',
        'revision': revision * 64,
        'enabled': enabled,
        'search': true,
      });

  setUp(() => SourceSite.pythonSources = [script()]);
  tearDown(() => SourceSite.pythonSources = []);

  test('scripts require an explicit viewer source grant', () async {
    SharedPreferences.setMockInitialValues({
      'profiles': jsonEncode([
        LocalProfile(
          id: 'default',
          name: '管理员',
          admin: true,
          salt: '0' * 32,
          pinHash: '1' * 64,
        ).toJson(),
        const LocalProfile(
          id: 'viewer',
          name: '普通用户',
          sources: ['hongguo'],
        ).toJson(),
      ]),
      'forceLogin': false,
    });
    final store = testStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    expect(store.allowsSource(source), isTrue);
    expect(SourceSite.byId(source).pagedSearch, isTrue);
    await store.switchProfile('viewer');
    expect(store.allowsSource(source), isFalse);
    expect(store.sources.any((site) => site.id == source), isFalse);

    final repository = NativeRepository()..access = store;
    await expectLater(repository.pythonSources(), throwsA(isA<AppFailure>()));
    await expectLater(
      repository.importPythonSource('synthetic.py', [1]),
      throwsA(isA<AppFailure>()),
    );
    await expectLater(
      repository.managePythonSource(source, 'delete'),
      throwsA(isA<AppFailure>()),
    );
  });

  test(
    'disable and removal preserve records and invalidate availability',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = testStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final drama = Drama(
        id: '$source:7',
        source: source,
        sourceId: '7',
        title: '合成记录',
      );
      await store.toggleFavorite(drama);
      final before = SourceSite.byId(source).identity;
      SourceSite.pythonSources = [script(revision: '2')];
      store.refreshSources();
      expect(SourceSite.byId(source).identity, isNot(before));
      SourceSite.pythonSources = [script(enabled: false)];
      store.refreshSources();
      expect(SourceSite.isAvailable(source), isFalse);
      expect(store.allowsSource(source), isFalse);
      final backup = jsonDecode(await store.exportBackup()) as Map;
      expect(jsonEncode(backup), contains('合成记录'));
      expect(jsonEncode(backup), isNot(contains('synthetic.py')));
      SourceSite.pythonSources = [];
      store.refreshSources();
      expect(SourceSite.byId(source).name, '已移除的 Python 站源');
      expect(SourceSite.isKnown(source), isTrue);
      expect(
        jsonEncode(jsonDecode(await store.exportBackup())),
        contains('合成记录'),
      );
    },
  );
}
