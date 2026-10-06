import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'app_layout.dart';
import 'app_orientation.dart';
import 'core_bridge.dart';
import 'diary_service.dart';
import 'live_models.dart';
import 'local_store.dart';
import 'luna_exo_player.dart';
import 'remote_widgets.dart';

class LivePlayerScreen extends StatefulWidget {
  const LivePlayerScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.channels,
    required this.initialChannel,
    this.playerFactory,
    this.videoBuilder,
  });

  final AppRepository repository;
  final LocalStore store;
  final List<LiveChannel> channels;
  final LiveChannel initialChannel;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(Widget controls)? videoBuilder;

  @override
  State<LivePlayerScreen> createState() => _LivePlayerScreenState();
}

class _LivePlayerScreenState extends State<LivePlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  VideoController? _video;
  late LiveChannel _channel;
  late final int _epoch;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  AppOrientationController? _orientation;
  LivePlayback? _playback;
  String? _playingChannel;
  Future<void> _operations = Future<void>.value();
  Timer? _healthTimer;
  Timer? _retryTimer;
  Timer? _errorTimer;
  Timer? _controlsTimer;
  final _surfaceFocus = FocusNode();
  final _playFocus = FocusNode();
  DateTime _lastProgress = DateTime.now();
  Duration _lastPosition = Duration.zero;
  int _generation = 0;
  int _retries = 0;
  Duration _healthyPlayback = Duration.zero;
  bool _closed = false;
  bool _loading = true;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _playIntent = true;
  bool _fullscreen = false;
  bool _channelPicker = false;
  bool _volumePicker = false;
  bool _catchupPicker = false;
  bool _seeking = false;
  DateTime? _catchupStart;
  DateTime? _catchupEnd;
  double? _seekPosition;
  bool _controlsVisible = true;
  bool _recovering = false;
  double _volume = 100;
  bool _volumeReady = !AppDevice.supportsMediaVolume;
  bool _settingVolume = false;
  double? _pendingVolume;
  String? _error;

  bool get _allowed =>
      !widget.store.locked && widget.store.profileEpoch == _epoch;

  @override
  void initState() {
    super.initState();
    _epoch = widget.store.profileEpoch;
    _channel = widget.initialChannel;
    _player =
        widget.playerFactory?.call() ??
        (Platform.isAndroid
            ? LunaExoPlayer()
            : Player(
                configuration: const PlayerConfiguration(
                  bufferSize: 16 * 1024 * 1024,
                  logLevel: MPVLogLevel.warn,
                ),
              ));
    if (widget.videoBuilder == null && !Platform.isAndroid) {
      _video = VideoController(
        _player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: !Platform.isIOS,
        ),
      );
    }
    WidgetsBinding.instance.addObserver(this);
    widget.store.addListener(_accessChanged);
    _subscriptions.add(
      _player.stream.error.listen((error) {
        if (_acceptErrors && !_closed && error.isNotEmpty) {
          DiaryService.add('[Live] 频道 ${_channel.id} 播放器报告: $error');
          _queueRecovery('直播暂时无法播放，请重新取流');
        }
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((position) {
        if (_closed) return;
        if (_catchupStart != null && mounted) setState(() {});
        if (position != _lastPosition) {
          final advance = position - _lastPosition;
          _lastPosition = position;
          _lastProgress = DateTime.now();
          if (!_loading &&
              _foreground &&
              _playIntent &&
              _playingChannel == _channel.id &&
              advance > Duration.zero &&
              advance <= const Duration(seconds: 10)) {
            _errorTimer?.cancel();
            if (_retryTimer?.isActive == true) {
              _retryTimer?.cancel();
              _acceptErrors = true;
              setState(() => _recovering = false);
              DiaryService.add('[Live] 频道 ${_channel.id} 已自行恢复，取消重新取流');
            }
            _healthyPlayback += advance;
            if (_retries > 0 &&
                _healthyPlayback >= const Duration(seconds: 30)) {
              _retries = 0;
              DiaryService.add('[Live] 频道 ${_channel.id} 已稳定播放，重置恢复次数');
            }
          }
        }
      }),
    );
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (!completed || !_acceptErrors || _closed) return;
        if (_catchupStart != null) {
          _retryTimer?.cancel();
          _errorTimer?.cancel();
          _acceptErrors = false;
          _playIntent = false;
          setState(() => _recovering = false);
          _showControls();
        } else {
          _recover('直播流已中断');
        }
      }),
    );
    _subscriptions.add(
      _player.stream.duration.listen((_) {
        if (!_closed && mounted && _catchupStart != null) setState(() {});
      }),
    );
    _subscriptions.add(
      _player.stream.playing.listen((playing) {
        if (mounted) setState(() {});
        if (playing) _scheduleControlsHide();
      }),
    );
    _subscriptions.add(
      _player.stream.buffering.listen((_) {
        if (mounted) setState(() {});
      }),
    );
    if (AppDevice.supportsMediaVolume) {
      _subscriptions.add(
        AppDevice.mediaVolumeChanges.listen(
          _receiveVolume,
          onError: (Object _) => DiaryService.add('[Live] 系统媒体音量监听失败'),
        ),
      );
      unawaited(
        AppDevice.getMediaVolume()
            .then(_receiveVolume)
            .catchError((Object _) => DiaryService.add('[Live] 系统媒体音量读取失败')),
      );
    }
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_loading &&
          !_seeking &&
          _error == null &&
          _playIntent &&
          _foreground &&
          _allowed &&
          DateTime.now().difference(_lastProgress) >
              const Duration(seconds: 30)) {
        _recover('直播长时间未更新，请重新取流');
      }
    });
    _load(_channel);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _orientation = AppOrientationScope.maybeOf(context);
  }

  void _accessChanged() {
    if (!_allowed && !_closed) {
      _generation++;
      _acceptErrors = false;
      _playIntent = false;
      _retryTimer?.cancel();
      _errorTimer?.cancel();
      unawaited(_player.pause());
      final playback = _playback;
      _playback = null;
      if (playback != null) unawaited(_release(playback));
      if (mounted) {
        setState(() {
          _loading = false;
          _recovering = false;
          _error = '当前用户已变更，请退出直播';
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closed) return;
    if (state == AppLifecycleState.inactive) return;
    if (state == AppLifecycleState.resumed) {
      final wasForeground = _foreground;
      _foreground = true;
      if (!wasForeground && _playIntent && _allowed) {
        _load(_channel, automatic: true);
      }
    } else {
      _foreground = false;
      _generation++;
      _acceptErrors = false;
      _retryTimer?.cancel();
      _errorTimer?.cancel();
      _controlsTimer?.cancel();
      unawaited(_player.pause());
    }
  }

  Future<void> _release(LivePlayback playback) async {
    try {
      await widget.repository.releaseLive(playback.session);
    } catch (_) {}
  }

  void _load(
    LiveChannel channel, {
    bool automatic = false,
    DateTime? start,
    DateTime? end,
  }) {
    if (_closed || !_allowed) return;
    final replayStart = automatic && channel.id == _channel.id
        ? _catchupStart
        : start;
    final replayEnd = automatic && channel.id == _channel.id
        ? _catchupEnd
        : end;
    final resume = automatic && replayStart != null
        ? _lastPosition
        : Duration.zero;
    final ticket = ++_generation;
    _retryTimer?.cancel();
    _errorTimer?.cancel();
    if (!automatic) _retries = 0;
    _healthyPlayback = Duration.zero;
    _acceptErrors = false;
    _playIntent = true;
    setState(() {
      _channel = channel;
      _catchupStart = replayStart;
      _catchupEnd = replayEnd;
      _seeking = false;
      _seekPosition = null;
      _loading = true;
      _recovering = automatic;
      _error = null;
    });
    if (!automatic) _showControls();
    _operations = _operations.catchError((Object _) {}).then((_) async {
      if (_closed || ticket != _generation || !_allowed) return;
      final previous = _playback;
      LivePlayback? playback;
      try {
        playback = await widget.repository.openLive(
          channel.id,
          start: replayStart,
          end: replayEnd,
          automatic: automatic,
        );
        if (_closed || ticket != _generation || !_allowed) {
          await _release(playback);
          return;
        }
        await _player.stop();
        _playingChannel = null;
        _playback = playback;
        if (previous != null) await _release(previous);
        final platform = _player.platform;
        if (platform is NativePlayer) {
          if (Platform.isIOS) await platform.setProperty('cache-on-disk', 'no');
          await platform.setProperty('network-timeout', '20');
        }
        DiaryService.add('[Live] 打开频道 ${channel.id}，第 ${_retries + 1} 次取流');
        await _player.open(
          Media(
            playback.url,
            httpHeaders: playback.headers,
            start: resume > Duration.zero ? resume : null,
          ),
          play: _foreground && _playIntent,
        );
        if (_closed || ticket != _generation || !_allowed) {
          await _player.stop();
          if (identical(_playback, playback)) {
            _playback = null;
            await _release(playback);
          }
          return;
        }
        await _player.setVolume(AppDevice.supportsMediaVolume ? 100 : _volume);
        if (!_foreground || !_playIntent) await _player.pause();
        if (_closed || ticket != _generation || !_allowed) {
          await _player.stop();
          if (identical(_playback, playback)) {
            _playback = null;
            await _release(playback);
          }
          return;
        }
        _playingChannel = channel.id;
        _lastPosition = _player.state.position;
        _lastProgress = DateTime.now();
        _acceptErrors = true;
        setState(() {
          _loading = false;
          _recovering = false;
        });
        _scheduleControlsHide();
      } catch (error) {
        if (playback != null) {
          await _release(playback);
          if (identical(_playback, playback)) _playback = null;
        }
        if (!_closed && ticket == _generation && _allowed) {
          final message = error is AppFailure ? error.message : '直播初始化失败，请重新取流';
          DiaryService.add('[Live] 频道 ${channel.id} 取流失败');
          _recover(message);
        }
      }
    });
  }

  void _queueRecovery(String message) {
    if (_errorTimer?.isActive == true ||
        !_foreground ||
        !_playIntent ||
        !_allowed) {
      return;
    }
    final ticket = _generation;
    _errorTimer = Timer(const Duration(seconds: 8), () {
      if (!_closed && ticket == _generation) _recover(message);
    });
  }

  void _recover(String message) {
    if (_closed ||
        !_foreground ||
        !_playIntent ||
        !_allowed ||
        _retryTimer?.isActive == true) {
      return;
    }
    _acceptErrors = false;
    _errorTimer?.cancel();
    _healthyPlayback = Duration.zero;
    if (_retries >= 3) {
      setState(() {
        _loading = false;
        _recovering = false;
        _error = message;
      });
      _showControls();
      return;
    }
    _retries++;
    setState(() {
      _loading = false;
      _recovering = true;
      _error = null;
    });
    final ticket = _generation;
    DiaryService.add('[Live] 频道 ${_channel.id} 自动恢复（$_retries/3）');
    _retryTimer = Timer(Duration(seconds: 1 << (_retries - 1)), () {
      if (!_closed &&
          ticket == _generation &&
          _allowed &&
          _foreground &&
          _playIntent) {
        _load(_channel, automatic: true);
      }
    });
  }

  void _changeChannel(int step) {
    final index = widget.channels.indexWhere(
      (channel) => channel.id == _channel.id,
    );
    _load(
      widget.channels[(index + step + widget.channels.length) %
          widget.channels.length],
    );
  }

  Future<void> _togglePlayback() async {
    if (_loading || !_allowed) return;
    if (_playIntent) {
      _playIntent = false;
      _retryTimer?.cancel();
      _errorTimer?.cancel();
      await _player.pause();
      if (mounted) {
        setState(() => _recovering = false);
        _showControls();
      }
    } else {
      if (_catchupStart != null && _playback != null) {
        final ticket = _generation;
        if (_player.state.completed &&
            _player.state.position >= _player.state.duration) {
          await _seekReplay(0);
        }
        if (_closed || !_allowed || ticket != _generation) return;
        _playIntent = true;
        _acceptErrors = true;
        _lastProgress = DateTime.now();
        try {
          await _player.play();
          if (mounted && !_closed && ticket == _generation) setState(() {});
        } catch (_) {
          if (!_closed && ticket == _generation) {
            _queueRecovery('回看暂时无法继续，请重新取流');
          }
        }
      } else {
        _load(_channel);
      }
    }
  }

  Future<void> _chooseCatchup() async {
    if (_catchupPicker || !_allowed || _channel.catchupDays == 0) return;
    _catchupPicker = true;
    _controlsTimer?.cancel();
    final channel = _channel;
    final ticket = _generation;
    try {
      final now = DateTime.now();
      final first = now.subtract(Duration(days: channel.catchupDays));
      final previous = _catchupStart ?? now.subtract(const Duration(hours: 1));
      final initial = previous.isBefore(first)
          ? first
          : previous.isAfter(now)
          ? now
          : previous;
      final date = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: first,
        lastDate: now,
        helpText: '选择回看日期',
      );
      if (date == null || !mounted || ticket != _generation || !_allowed) {
        return;
      }
      final clock = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(initial),
        helpText: '选择回看开始时间',
      );
      if (clock == null || !mounted || ticket != _generation || !_allowed) {
        return;
      }
      final start = DateTime(
        date.year,
        date.month,
        date.day,
        clock.hour,
        clock.minute,
      );
      final current = DateTime.now();
      if (!start.isBefore(current) ||
          start.isBefore(
            current.subtract(Duration(days: channel.catchupDays)),
          )) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请选择过去七天内的回看时间')));
        return;
      }
      final limit = start.add(const Duration(hours: 2));
      _load(
        channel,
        start: start,
        end: limit.isAfter(current) ? current : limit,
      );
    } finally {
      _catchupPicker = false;
      _showControls();
    }
  }

  Future<void> _seekReplay(double position) async {
    if (_closed || !_allowed || _catchupStart == null) return;
    final ticket = _generation;
    _operations = _operations.catchError((Object _) {}).then((_) async {
      if (_closed || ticket != _generation || !_allowed) return;
      try {
        await _player.seek(Duration(milliseconds: position.round()));
        _lastProgress = DateTime.now();
      } catch (_) {
        if (mounted && !_closed && ticket == _generation) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('回看跳转失败，请重试')));
        }
      } finally {
        if (mounted && !_closed && ticket == _generation) {
          setState(() {
            _seeking = false;
            _seekPosition = null;
          });
          _showControls();
        }
      }
    });
    await _operations;
  }

  Widget _replayBar() {
    final duration = _player.state.duration.inMilliseconds.toDouble();
    final maximum = duration > 0 ? duration : 1.0;
    final position =
        (_seekPosition ?? _player.state.position.inMilliseconds.toDouble())
            .clamp(0.0, maximum);
    final clock = _catchupStart!.add(Duration(milliseconds: position.round()));
    String pad(int number) => number.toString().padLeft(2, '0');
    return Container(
      key: const ValueKey('live-replay-progress'),
      color: Colors.black.withValues(alpha: .65),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text(
            '回看 ${pad(clock.month)}-${pad(clock.day)} ${pad(clock.hour)}:${pad(clock.minute)}',
          ),
          Expanded(
            child: Slider(
              value: position,
              max: maximum,
              onChanged: !_loading && _allowed && duration > 0
                  ? (value) {
                      _controlsTimer?.cancel();
                      setState(() {
                        _seeking = true;
                        _seekPosition = value;
                      });
                    }
                  : null,
              onChangeEnd: (value) => unawaited(_seekReplay(value)),
            ),
          ),
        ],
      ),
    );
  }

  void _receiveVolume(double value) {
    if (!_closed && mounted) {
      setState(() {
        _volume = value.clamp(0.0, 1.0) * 100;
        _volumeReady = true;
      });
    }
  }

  void _setVolume(double value) {
    if (_closed || !_allowed || !_volumeReady) return;
    if (!AppDevice.supportsMediaVolume) {
      setState(() => _volume = value);
      unawaited(_player.setVolume(value));
      return;
    }
    _pendingVolume = value;
    if (!_settingVolume) unawaited(_flushVolume());
  }

  Future<void> _flushVolume() async {
    _settingVolume = true;
    try {
      while (!_closed && _allowed && _pendingVolume != null) {
        final value = _pendingVolume!;
        _pendingVolume = null;
        await AppDevice.setMediaVolume(value / 100);
      }
    } catch (_) {
      DiaryService.add('[Live] 系统媒体音量调整失败');
      if (!_closed && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('系统媒体音量调整失败')));
      }
    } finally {
      _pendingVolume = null;
      _settingVolume = false;
    }
  }

  Future<void> _setFullscreen(bool value) async {
    if (_closed) return;
    setState(() => _fullscreen = value);
    _showControls();
    await _orientation?.setPlayback(
      this,
      fullscreen: value,
      aspectRatio: 16 / 9,
    );
  }

  Future<void> _chooseChannel() async {
    if (_channelPicker || !_allowed) return;
    _channelPicker = true;
    _controlsTimer?.cancel();
    final selectedIndex = widget.channels.indexWhere(
      (channel) => channel.id == _channel.id,
    );
    final scroll = ScrollController(
      initialScrollOffset:
          selectedIndex.clamp(0, widget.channels.length - 1) * 88.0,
    );
    try {
      final selected = await showDialog<LiveChannel>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('选择频道'),
          content: SizedBox(
            width: 480,
            height: 420,
            child: ListView.builder(
              controller: scroll,
              itemExtent: 88,
              itemCount: widget.channels.length,
              itemBuilder: (context, index) {
                final channel = widget.channels[index];
                return RemoteTarget(
                  selected: channel.id == _channel.id,
                  autofocus: channel.id == _channel.id,
                  onPressed: () => Navigator.pop(context, channel),
                  child: ListTile(
                    title: Text(channel.name),
                    subtitle: Text(channel.group),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      if (selected != null && !_closed) _load(selected);
    } finally {
      scroll.dispose();
      _channelPicker = false;
      _showControls();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    _retryTimer?.cancel();
    _errorTimer?.cancel();
    _controlsTimer?.cancel();
    _healthTimer?.cancel();
    _surfaceFocus.dispose();
    _playFocus.dispose();
    widget.store.removeListener(_accessChanged);
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_orientation?.releasePlayback(this) ?? Future<void>.value());
    unawaited(_player.pause());
    unawaited(
      _operations.catchError((Object _) {}).then((_) async {
        final playback = _playback;
        try {
          await _player.dispose();
        } finally {
          if (playback != null) await _release(playback);
        }
      }),
    );
    super.dispose();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (_closed ||
        !_foreground ||
        !_playIntent ||
        !_player.state.playing ||
        _loading ||
        _error != null ||
        _channelPicker ||
        _volumePicker ||
        _catchupPicker ||
        _seeking) {
      return;
    }
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (!_closed &&
          mounted &&
          !_channelPicker &&
          !_volumePicker &&
          !_catchupPicker &&
          !_seeking &&
          _playIntent &&
          _error == null) {
        _surfaceFocus.requestFocus();
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (_closed || !mounted) return;
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleControlsHide();
  }

  void _toggleControls() {
    if (_closed || !_allowed) return;
    setState(() => _controlsVisible = !_controlsVisible);
    _surfaceFocus.requestFocus();
    _scheduleControlsHide();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    const navigation = [
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.select,
    ];
    if (!navigation.contains(event.logicalKey)) return KeyEventResult.ignored;
    final hidden = !_controlsVisible;
    _showControls();
    if (hidden && AppLayout.isTelevision(context)) {
      _playFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _controlBar() => LayoutBuilder(
    builder: (context, constraints) {
      final buttonCount = _channel.catchupDays > 0 ? 8 : 7;
      final buttonWidth = ((constraints.maxWidth - 16) / buttonCount).clamp(
        32.0,
        48.0,
      );
      Widget button(Widget child) =>
          SizedBox(width: buttonWidth, height: 48, child: child);
      return Container(
        key: const ValueKey('live-control-bar'),
        color: Colors.black.withValues(alpha: .65),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            button(
              IconButton(
                tooltip: '上一个频道',
                onPressed: _allowed ? () => _changeChannel(-1) : null,
                icon: const Icon(Icons.skip_previous),
              ),
            ),
            button(
              IconButton(
                focusNode: _playFocus,
                autofocus: AppLayout.isTelevision(context),
                tooltip: _playIntent
                    ? '暂停'
                    : _catchupStart == null
                    ? '播放直播'
                    : '播放回看',
                onPressed: _allowed && !_loading ? _togglePlayback : null,
                icon: Icon(_playIntent ? Icons.pause : Icons.play_arrow),
              ),
            ),
            button(
              IconButton(
                tooltip: '下一个频道',
                onPressed: _allowed ? () => _changeChannel(1) : null,
                icon: const Icon(Icons.skip_next),
              ),
            ),
            Expanded(
              child: constraints.maxWidth >= 600
                  ? Text(
                      '${_catchupStart == null ? '直播' : '回看'} · ${_channel.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : const SizedBox.shrink(),
            ),
            button(
              IconButton(
                tooltip: '频道',
                onPressed: _allowed ? _chooseChannel : null,
                icon: const Icon(Icons.list),
              ),
            ),
            if (_channel.catchupDays > 0)
              button(
                IconButton(
                  tooltip: '七天回看',
                  onPressed: _allowed && !_loading ? _chooseCatchup : null,
                  icon: const Icon(Icons.history),
                ),
              ),
            button(
              IconButton(
                tooltip: '回到直播',
                onPressed: _allowed ? () => _load(_channel) : null,
                icon: const Icon(Icons.refresh),
              ),
            ),
            button(
              PopupMenuButton<double>(
                tooltip: '音量',
                enabled: _volumeReady && _allowed,
                icon: const Icon(Icons.volume_up),
                initialValue: _volume,
                onOpened: () {
                  _volumePicker = true;
                  _controlsTimer?.cancel();
                },
                onCanceled: () {
                  _volumePicker = false;
                  _showControls();
                },
                onSelected: (value) {
                  _volumePicker = false;
                  _setVolume(value);
                  _showControls();
                },
                itemBuilder: (_) => [
                  for (final value in [0.0, 25.0, 50.0, 75.0, 100.0])
                    PopupMenuItem(
                      value: value,
                      child: Text('音量 ${value.round()}%'),
                    ),
                ],
              ),
            ),
            button(
              IconButton(
                tooltip: _fullscreen ? '退出全屏' : '全屏',
                onPressed: () => _setFullscreen(!_fullscreen),
                icon: Icon(
                  _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _videoPane() {
    final overlay = MouseRegion(
      onHover: (_) => _showControls(),
      cursor: _controlsVisible
          ? SystemMouseCursors.basic
          : SystemMouseCursors.none,
      child: Listener(
        onPointerDown: (_) {
          if (_controlsVisible) _scheduleControlsHide();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const ValueKey('live-gesture-surface'),
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              child: const SizedBox.expand(),
            ),
            if (_loading)
              const IgnorePointer(
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_recovering && !_loading)
              Positioned(
                top: 12,
                right: 12,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Color(0x99000000),
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        _catchupStart == null ? '正在恢复直播…' : '正在恢复回看…',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            Align(
              alignment: Alignment.bottomCenter,
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: ExcludeFocus(
                  excluding: !_controlsVisible,
                  child: AnimatedOpacity(
                    key: const ValueKey('live-controls'),
                    opacity: _controlsVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_catchupStart != null) _replayBar(),
                        _controlBar(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_error != null)
              Center(
                child: Container(
                  margin: const EdgeInsets.all(20),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .8),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _allowed
                            ? () => _load(
                                _channel,
                                start: _catchupStart,
                                end: _catchupEnd,
                              )
                            : null,
                        child: const Text('重新取流'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: ColoredBox(
        color: Colors.black,
        child: widget.videoBuilder != null
            ? widget.videoBuilder!(overlay)
            : _player is LunaExoPlayer
            ? LunaExoVideoView(player: _player, controls: (_) => overlay)
            : Video(
                controller: _video!,
                fit: BoxFit.contain,
                controls: (_) => overlay,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final television = AppLayout.isTelevision(context);
    return PopScope(
      canPop: !_fullscreen || television,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) _setFullscreen(false);
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.pageUp): () =>
              _changeChannel(-1),
          const SingleActivator(LogicalKeyboardKey.pageDown): () =>
              _changeChannel(1),
          const SingleActivator(LogicalKeyboardKey.space): () =>
              unawaited(_togglePlayback()),
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_fullscreen) {
              _setFullscreen(false);
            } else {
              Navigator.maybePop(context);
            }
          },
        },
        child: Focus(
          focusNode: _surfaceFocus,
          onKeyEvent: _handleKey,
          autofocus: !television,
          child: Scaffold(
            appBar: _fullscreen
                ? null
                : AppBar(
                    title: Text(_channel.name),
                    actions: [
                      IconButton(
                        tooltip: '播放日记',
                        onPressed: () => DiaryService.showDiaryDialog(context),
                        icon: const Icon(Icons.receipt_long),
                      ),
                    ],
                  ),
            body: SafeArea(
              child: _fullscreen || television
                  ? _videoPane()
                  : Column(
                      children: [
                        Expanded(
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: 16 / 9,
                              child: _videoPane(),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              Text('${_channel.group} · 直播画质以实际输出为准'),
                              Row(
                                children: [
                                  const Icon(Icons.volume_up),
                                  Expanded(
                                    child: Slider(
                                      value: _volume,
                                      min: 0,
                                      max: 100,
                                      onChanged: _volumeReady && _allowed
                                          ? _setVolume
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                _catchupStart == null
                                    ? '暂停后继续将回到直播。支持 PageUp / PageDown 换台、空格播放 / 暂停。'
                                    : '回看可拖动进度条；暂停后继续从当前位置播放，点击「回到直播」返回当前节目。',
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
