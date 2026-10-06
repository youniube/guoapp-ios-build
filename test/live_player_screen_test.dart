import 'dart:async';

import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/live_player_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

const liveFixtureChannels = [
  LiveChannel(id: 'cctv6', name: 'CCTV-6 电影', group: '央视', catchupDays: 7),
  LiveChannel(id: 'cctv1', name: 'CCTV-1 综合', group: '央视'),
  LiveChannel(id: 'cctv2', name: 'CCTV-2 财经', group: '央视'),
];

class LiveFixtureRepository extends FixtureRepository {
  int opens = 0;
  bool deferNext = false;
  Completer<LivePlayback>? pending;
  final active = <String>{};
  final failedChannels = <String>{};
  final liveRequests = <({DateTime? start, DateTime? end, bool automatic})>[];

  LivePlayback playback(String channel) {
    final session = 'live-$opens';
    active.add(session);
    return LivePlayback(
      url: 'https://media.test/$channel/$session.m3u8',
      session: session,
    );
  }

  @override
  Future<LivePlayback> openLive(
    String channel, {
    DateTime? start,
    DateTime? end,
    bool automatic = false,
  }) async {
    opens++;
    liveRequests.add((start: start, end: end, automatic: automatic));
    if (failedChannels.contains(channel)) {
      throw AppFailure('synthetic channel unavailable');
    }
    if (deferNext) {
      deferNext = false;
      pending = Completer<LivePlayback>();
      return pending!.future;
    }
    return playback(channel);
  }

  @override
  Future<void> releaseLive(String session) async {
    active.remove(session);
  }
}

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var index = 0; index < 12; index++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> mount(
    WidgetTester tester,
    LiveFixtureRepository repository,
    ScriptedPlayer player, {
    bool television = false,
    Size size = const Size(390, 844),
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final store = LocalStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        home: AppLayout(
          television: television,
          child: LivePlayerScreen(
            repository: repository,
            store: store,
            channels: liveFixtureChannels,
            initialChannel: liveFixtureChannels.first,
            playerFactory: () => Player(platformPlayer: player),
            videoBuilder: (controls) => controls,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> unmount(
    WidgetTester tester,
    LiveFixtureRepository repository,
    ScriptedPlayer player,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    expect(player.disposed, isTrue);
    expect(repository.active, isEmpty);
    expect(tester.takeException(), isNull);
  }

  Future<void> chooseReplay(WidgetTester tester) async {
    await tester.tap(find.byTooltip('七天回看'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(DatePickerDialog),
            matching: find.byType(TextButton),
          )
          .last,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(TimePickerDialog),
            matching: find.byType(TextButton),
          )
          .last,
    );
    await settle(tester);
  }

  test('live channel metadata preserves replay support and EPG identity', () {
    final channel = LiveChannel.fromJson({
      'id': 'cctv1',
      'name': 'CCTV-1 综合',
      'group': '央视频道',
      'epgId': 'CCTV1',
      'epgUrl': 'https://live.fanmingming.com/e.xml',
      'catchupDays': 7,
    });
    expect(channel.catchupDays, 7);
    expect(channel.epgId, 'CCTV1');
    expect(channel.epgUrl, 'https://live.fanmingming.com/e.xml');
    expect(
      LiveChannel.fromJson({
        'id': 'cctv4k',
        'name': 'CCTV-4K',
        'group': '央视频道',
      }).catchupDays,
      0,
    );
  });

  testWidgets('replay pauses, seeks and completes without reopening live', (
    tester,
  ) async {
    final repository = LiveFixtureRepository();
    final player = ScriptedPlayer();
    await mount(tester, repository, player);
    await chooseReplay(tester);
    final request = repository.liveRequests.last;
    expect(request.start, isNotNull);
    expect(request.end!.isAfter(request.start!), isTrue);
    expect(
      request.end!.difference(request.start!).inSeconds,
      lessThanOrEqualTo(7200),
    );
    expect(find.byKey(const ValueKey('live-replay-progress')), findsOneWidget);
    await tester.tap(find.byTooltip('暂停'));
    await settle(tester);
    final slider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(const ValueKey('live-replay-progress')),
        matching: find.byType(Slider),
      ),
    );
    slider.onChanged!(45000);
    slider.onChangeEnd!(45000);
    await settle(tester);
    expect(player.state.position, const Duration(seconds: 45));
    await tester.tap(find.byTooltip('播放回看'));
    await settle(tester);
    expect(repository.opens, 2);
    expect(player.state.position, const Duration(seconds: 45));
    player.finishEpisode();
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(repository.opens, 2);
    expect(find.byTooltip('播放回看'), findsOneWidget);
    expect(find.text('重新取流'), findsNothing);
    await unmount(tester, repository, player);
  });

  testWidgets('replay recovery retains its time window and position', (
    tester,
  ) async {
    final repository = LiveFixtureRepository();
    final player = ScriptedPlayer();
    await mount(tester, repository, player);
    await chooseReplay(tester);
    final replay = repository.liveRequests.last;
    await player.seek(const Duration(seconds: 45));
    await tester.pump();
    player.fail();
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(repository.liveRequests.last.start, replay.start);
    expect(repository.liveRequests.last.end, replay.end);
    expect(repository.liveRequests.last.automatic, isTrue);
    expect(player.opened.last.start, const Duration(seconds: 45));
    await tester.tap(find.byKey(const ValueKey('live-gesture-surface')));
    await settle(tester);
    await tester.tap(find.byTooltip('回到直播'));
    await settle(tester);
    expect(repository.liveRequests.last.start, isNull);
    expect(repository.liveRequests.last.end, isNull);
    expect(repository.liveRequests.last.automatic, isFalse);
    expect(find.byKey(const ValueKey('live-replay-progress')), findsNothing);
    expect(repository.active, hasLength(1));
    await unmount(tester, repository, player);
  });

  testWidgets('manual replay retry preserves the chosen time window', (
    tester,
  ) async {
    final repository = LiveFixtureRepository();
    final player = ScriptedPlayer();
    await mount(tester, repository, player);
    await chooseReplay(tester);
    final replay = repository.liveRequests.last;
    repository.failedChannels.add(liveFixtureChannels.first.id);
    player.fail();
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    for (final delay in [1, 2, 4]) {
      await tester.pump(Duration(seconds: delay));
      await settle(tester);
    }
    expect(find.text('重新取流'), findsOneWidget);
    repository.failedChannels.clear();
    await tester.tap(find.text('重新取流'));
    await settle(tester);
    expect(repository.liveRequests.last.start, replay.start);
    expect(repository.liveRequests.last.end, replay.end);
    expect(repository.liveRequests.last.automatic, isFalse);
    expect(find.byKey(const ValueKey('live-replay-progress')), findsOneWidget);
    await unmount(tester, repository, player);
  });

  testWidgets(
    'live controls stay on one row and hide until the video is tapped',
    (tester) async {
      final repository = LiveFixtureRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      expect(
        tester.getSize(find.byKey(const ValueKey('live-control-bar'))).height,
        48,
      );
      await tester.pump(const Duration(seconds: 4));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('live-controls')),
            )
            .opacity,
        0,
      );
      expect(find.byTooltip('暂停').hitTestable(), findsNothing);
      await tester.tap(find.byKey(const ValueKey('live-gesture-surface')));
      await tester.pump();
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('live-controls')),
            )
            .opacity,
        1,
      );
      await unmount(tester, repository, player);
    },
  );

  testWidgets(
    'a transient decoder error followed by progress does not reopen live playback',
    (tester) async {
      final repository = LiveFixtureRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      player.fail();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await player.seek(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(repository.opens, 1);
      expect(find.text('重新取流'), findsNothing);
      expect(find.text('正在恢复直播…'), findsNothing);
      await unmount(tester, repository, player);
    },
  );

  testWidgets(
    'manual retry appears only after three failed automatic recoveries',
    (tester) async {
      final repository = LiveFixtureRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      for (final delay in [1, 2, 4]) {
        player.fail();
        await tester.pump();
        await tester.pump(const Duration(seconds: 8));
        expect(find.text('重新取流'), findsNothing);
        await tester.pump(Duration(seconds: delay));
        await settle(tester);
      }
      expect(repository.opens, 4);
      player.fail();
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));
      expect(find.text('重新取流'), findsOneWidget);
      await tester.pump(const Duration(seconds: 20));
      expect(repository.opens, 4);
      await tester.tap(find.text('重新取流'));
      await settle(tester);
      expect(repository.opens, 5);
      expect(find.text('重新取流'), findsNothing);
      await unmount(tester, repository, player);
    },
  );

  testWidgets(
    'thirty seconds of recovered playback restores the retry budget',
    (tester) async {
      final repository = LiveFixtureRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      for (final delay in [1, 2]) {
        player.fail();
        await tester.pump();
        await tester.pump(const Duration(seconds: 8));
        await tester.pump(Duration(seconds: delay));
        await settle(tester);
      }
      for (final position in [10, 20, 30]) {
        await player.seek(Duration(seconds: position));
        await tester.pump();
      }
      player.fail();
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(repository.opens, 4);
      expect(find.text('重新取流'), findsNothing);
      await unmount(tester, repository, player);
    },
  );

  testWidgets(
    'switching channels keeps the old stream until resolution and frees stale sessions',
    (tester) async {
      final repository = LiveFixtureRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      final initialURL = player.opened.last.uri;
      repository.deferNext = true;
      await tester.tap(find.byTooltip('下一个频道'));
      await settle(tester);
      expect(player.opened.last.uri, initialURL);
      expect(repository.active, hasLength(1));
      await tester.tap(find.byTooltip('下一个频道'));
      await tester.pump();
      repository.pending!.complete(repository.playback('cctv1'));
      await settle(tester);
      expect(player.opened.last.uri, contains('/cctv2/'));
      expect(repository.active, hasLength(1));
      await unmount(tester, repository, player);
    },
  );

  testWidgets(
    'progress from the previous channel cannot cancel a failed channel switch',
    (tester) async {
      final repository = LiveFixtureRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      repository.failedChannels.add('cctv1');
      await tester.tap(find.byTooltip('下一个频道'));
      await settle(tester);
      await player.seek(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(repository.opens, 3);
      expect(player.opened, hasLength(1));
      expect(find.text('正在恢复直播…'), findsOneWidget);
      await unmount(tester, repository, player);
    },
  );

  testWidgets('temporary iOS inactivity does not resolve the channel again', (
    tester,
  ) async {
    final repository = LiveFixtureRepository();
    final player = ScriptedPlayer();
    await mount(tester, repository, player);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(repository.opens, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(repository.opens, 2);
    await unmount(tester, repository, player);
  });

  testWidgets(
    'the first TV remote confirm wakes hidden controls without pausing',
    (tester) async {
      final repository = LiveFixtureRepository();
      final player = ScriptedPlayer();
      await mount(
        tester,
        repository,
        player,
        television: true,
        size: const Size(1280, 720),
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(player.state.playing, isTrue);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('live-controls')),
            )
            .opacity,
        1,
      );
      await unmount(tester, repository, player);
    },
  );
}
