import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'app_layout.dart';
import 'diary_service.dart';
import 'widgets.dart';

enum SwipeAction { none, seek, brightness, volume }

class GestureHudState {
  const GestureHudState({this.type = SwipeAction.none, this.value = 0.0});
  final SwipeAction type;
  final double value; // 0.0 ~ 1.0
}

class PlayerInteractions extends ChangeNotifier {
  PlayerInteractions({
    required this.player,
    required this.available,
    required this.baseSpeed,
    required this.onTogglePlayback,
    required this.onFullscreen,
    required this.onEpisode,
    this.onSeek,
    this.seekStepSeconds,
  }) {
    _playing = player.stream.playing.listen((playing) {
      if (!playing && !_scrubbing) cancel();
    });
    AppDevice.getBrightness()
        .then((val) {
          if (!_disposed) {
            _brightness = val;
            notifyListeners();
          }
        })
        .catchError((_) {});
    if (AppDevice.supportsMediaVolume) {
      _mediaVolumeSubscription = AppDevice.mediaVolumeChanges.listen(
        _systemVolumeChanged,
        onError: (Object error) => _volumeFailed(error, feedback: false),
      );
      unawaited(
        AppDevice.getMediaVolume()
            .then((value) {
              if (!_disposed) _systemVolumeChanged(value);
            })
            .catchError((Object error) {
              _volumeFailed(error, feedback: false);
            }),
      );
    }
  }

  final Player player;
  final bool Function() available;
  final double Function() baseSpeed;
  final VoidCallback onTogglePlayback;
  final VoidCallback onFullscreen;
  final String Function(int direction) onEpisode;
  final Future<void> Function(Duration)? onSeek;
  final int Function()? seekStepSeconds;
  late final StreamSubscription<bool> _playing;
  StreamSubscription<double>? _mediaVolumeSubscription;
  double? _systemVolume;
  double? _pendingSystemVolume;
  double? _volumeDelta;
  bool _volumeReady = false;
  bool _changingSystemVolume = false;
  int _volumeGesture = 0;
  Timer? _holdTimer;
  Timer? _hintTimer;
  Future<void> _rates = Future<void>.value();
  final Set<int> _pointers = {};
  int? _pointer;
  Offset? _origin;
  bool _swipeEnabled = false;
  bool _moved = false;
  bool _held = false;
  bool _boosting = false;
  bool _keyboardHold = false;
  bool _cancelUntilRelease = false;
  bool _disposed = false;
  double _unmutedVolume = 100;
  String _feedback = '';
  DateTime _ignoreTapUntil = DateTime(2000);
  SwipeAction _swipeAction = SwipeAction.none;
  GestureHudState _hudState = const GestureHudState();
  double _brightness = 0.5;
  double _initialBrightness = 0.5;
  double _initialVolume = 100;
  double _viewWidth = 0.0;
  double _viewHeight = 0.0;
  Timer? _hudTimer;
  Timer? _previewTimer;
  Future<void> _scrubOperations = Future<void>.value();
  int _scrubSequence = 0;
  bool _scrubbing = false;
  bool _scrubEnding = false;
  bool _previewQueued = false;
  bool _resumeAfterScrub = false;
  Duration _scrubStart = Duration.zero;
  Duration? _scrubTarget;

  GestureHudState get hudState => _hudState;
  double get brightness => _brightness;
  bool get isBrightnessActive => _hudState.type == SwipeAction.brightness;
  bool get scrubbing => _scrubbing;
  Duration? get scrubTarget => _scrubTarget;

  void setBrightnessDirect(double value) {
    if (_disposed) return;
    _brightness = value.clamp(0.01, 1.0);
    AppDevice.setBrightness(_brightness);
    _showHud(SwipeAction.brightness, _brightness);
  }

  void dismissBrightnessHud() {
    _scheduleDismissHud();
  }

  String get feedback => _feedback;
  bool get boosting => _boosting;
  bool get suppressTap => DateTime.now().isBefore(_ignoreTapUntil);
  Future<void> get pendingRates => _rates;

  void _systemVolumeChanged(double value) {
    if (_disposed) return;
    _systemVolume = value * 100;
    if (value > 0) _unmutedVolume = _systemVolume!;
    if (_hudState.type == SwipeAction.volume) {
      _showHud(SwipeAction.volume, value);
      if (_pointer == null || _swipeAction != SwipeAction.volume) {
        _scheduleDismissHud();
      }
    }
  }

  void _volumeFailed(Object error, {bool feedback = true}) {
    if (_disposed) return;
    DiaryService.add('[Volume] 系统媒体音量失败: $error');
    if (feedback) {
      hint('系统音量调节失败，请使用音量键重试');
    }
  }

  void _setSwipeVolume(double deltaRatio) {
    _volumeDelta = deltaRatio;
    if (AppDevice.supportsMediaVolume && !_volumeReady) return;
    final volume = (_initialVolume + deltaRatio * 100).clamp(0.0, 100.0);
    _setVolume(volume, hud: true);
  }

  void _setVolume(double volume, {required bool hud}) {
    if (_disposed || !available()) return;
    if (AppDevice.supportsMediaVolume) {
      _pendingSystemVolume = volume;
      _showHud(SwipeAction.volume, (_systemVolume ?? _initialVolume) / 100);
      if (_pointer == null || _swipeAction != SwipeAction.volume) {
        _scheduleDismissHud();
      }
      if (!_changingSystemVolume) unawaited(_flushSystemVolume());
      return;
    }
    unawaited(player.setVolume(volume));
    if (volume > 0) _unmutedVolume = volume;
    if (hud) {
      _showHud(SwipeAction.volume, volume / 100);
    } else {
      hint(volume == 0 ? '已静音' : '音量 ${volume.round()}%');
    }
  }

  Future<void> _flushSystemVolume() async {
    _changingSystemVolume = true;
    try {
      if (player.state.volume != 100) await player.setVolume(100);
      while (!_disposed && available() && _pendingSystemVolume != null) {
        final volume = _pendingSystemVolume!;
        _pendingSystemVolume = null;
        await AppDevice.setMediaVolume(volume / 100);
      }
    } catch (error) {
      _volumeFailed(error);
    } finally {
      _pendingSystemVolume = null;
      _changingSystemVolume = false;
    }
  }

  void hint(String message, {bool persistent = false}) {
    if (_disposed) return;
    _hintTimer?.cancel();
    if (_feedback != message) {
      _feedback = message;
      notifyListeners();
    }
    if (!persistent && message.isNotEmpty) {
      _hintTimer = Timer(const Duration(milliseconds: 1200), () {
        hint(_boosting ? '3 倍速 · 松开恢复' : '', persistent: true);
      });
    }
  }

  Future<void> applySpeed() => _setRate(baseSpeed());

  Future<void> _setRate(double value) {
    _rates = _rates
        .catchError((Object _) {})
        .then((_) => player.setRate(value));
    unawaited(
      _rates.catchError((Object _) {
        hint('倍速调整失败，请重试');
      }),
    );
    return _rates;
  }

  void _beginHold({bool keyboard = false}) {
    if (!available() || _scrubbing || _holdTimer != null || _boosting) return;
    _keyboardHold = keyboard;
    _holdTimer = Timer(const Duration(milliseconds: 350), () {
      _holdTimer = null;
      if (_disposed ||
          !available() ||
          !player.state.playing ||
          player.state.completed) {
        return;
      }
      _boosting = true;
      _held = true;
      unawaited(_setRate(3));
      hint('3 倍速 · 松开恢复', persistent: true);
    });
  }

  void _endHold({bool tap = false, bool silent = false}) {
    final wasKeyboard = _keyboardHold;
    final boosted = _boosting;
    _holdTimer?.cancel();
    _holdTimer = null;
    _keyboardHold = false;
    _boosting = false;
    if (boosted) {
      unawaited(_setRate(baseSpeed()));
      if (!silent) hint('恢复 ${baseSpeed()} 倍速');
    } else if (tap && wasKeyboard) {
      seek(5);
    }
  }

  void cancel({bool resumeScrub = false}) {
    if (_disposed) return;
    _volumeGesture++;
    _pendingSystemVolume = null;
    _volumeDelta = null;
    final resume = resumeScrub && _scrubbing && _resumeAfterScrub;
    _previewTimer?.cancel();
    _previewTimer = null;
    final ticket = ++_scrubSequence;
    _scrubbing = resume;
    _scrubEnding = resume;
    _scrubTarget = null;
    _previewQueued = false;
    if (resume) {
      _scrubOperations = _scrubOperations
          .catchError((Object _) {})
          .then((_) async {
            if (_disposed || ticket != _scrubSequence) return;
            try {
              if (available()) await player.play();
            } finally {
              if (!_disposed && ticket == _scrubSequence) {
                _scrubbing = _scrubEnding = false;
                notifyListeners();
              }
            }
          })
          .catchError((Object _) {});
    }
    if (_pointers.isNotEmpty) {
      _cancelUntilRelease = true;
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _pointer = null;
    _origin = null;
    _swipeAction = SwipeAction.none;
    _hudTimer?.cancel();
    _hudState = const GestureHudState();
    _endHold(silent: true);
    hint('');
    notifyListeners();
  }

  void pointerDown(
    PointerDownEvent event, {
    required bool swipeEnabled,
    double width = 0.0,
    required double height,
  }) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1 || _cancelUntilRelease) {
      cancel(resumeScrub: true);
      return;
    }
    if (!available() || _scrubbing || event.buttons != kPrimaryButton) return;
    _pointer = event.pointer;
    _origin = event.localPosition;
    _swipeEnabled = swipeEnabled && event.kind == PointerDeviceKind.touch;
    _viewWidth = width;
    _viewHeight = height;
    _moved = _held = false;
    _swipeAction = SwipeAction.none;
    _initialBrightness = _brightness;
    _initialVolume = player.state.volume.clamp(0.0, 100.0);
    _volumeDelta = null;
    _volumeReady = !AppDevice.supportsMediaVolume;
    final volumeTicket = ++_volumeGesture;
    if (_swipeEnabled &&
        event.localPosition.dx >= width * .35 &&
        AppDevice.supportsMediaVolume) {
      unawaited(
        AppDevice.getMediaVolume()
            .then((value) {
              if (_disposed || volumeTicket != _volumeGesture || !available()) {
                return;
              }
              _systemVolumeChanged(value);
              _initialVolume = value * 100;
              _volumeReady = true;
              if (_swipeAction == SwipeAction.volume && _volumeDelta != null) {
                _setSwipeVolume(_volumeDelta!);
              }
            })
            .catchError((Object error) {
              if (!_disposed && volumeTicket == _volumeGesture) {
                _volumeFailed(error);
              }
            }),
      );
    }
    if (_swipeEnabled && event.localPosition.dx < width * .35) {
      unawaited(
        AppDevice.getBrightness().then((value) {
          if (!_disposed &&
              _pointer == event.pointer &&
              _swipeAction == SwipeAction.none) {
            _initialBrightness = _brightness = value;
          }
        }),
      );
    }
    _beginHold();
  }

  void pointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _origin == null) return;
    final diff = event.localPosition - _origin!;
    if (diff.distance > 12) {
      _moved = true;
      _endHold();
    }
    if (!_swipeEnabled ||
        !_moved ||
        _held ||
        _viewHeight <= 0 ||
        _viewWidth <= 0)
      return;

    if (_swipeAction == SwipeAction.none) {
      if (diff.dx.abs() > diff.dy.abs() * 1.5) {
        _swipeAction = SwipeAction.seek;
        beginScrub();
      } else if (diff.dy.abs() > diff.dx.abs() * 1.5) {
        _swipeAction = _origin!.dx < _viewWidth * .35
            ? SwipeAction.brightness
            : SwipeAction.volume;
      } else {
        return;
      }
    }

    if (_swipeAction == SwipeAction.seek) {
      final span = math.min(120000, player.state.duration.inMilliseconds);
      updateScrub(
        Duration(
          milliseconds:
              _scrubStart.inMilliseconds +
              (diff.dx / _viewWidth * span).round(),
        ),
      );
      return;
    }

    final dy = _origin!.dy - event.localPosition.dy; // 向上滑动为增加，向下滑动为减少
    final deltaRatio = dy / (_viewHeight * 0.6);

    if (_swipeAction == SwipeAction.brightness) {
      _brightness = (_initialBrightness + deltaRatio).clamp(0.01, 1.0);
      AppDevice.setBrightness(_brightness);
      _showHud(SwipeAction.brightness, _brightness);
    } else if (_swipeAction == SwipeAction.volume) {
      _setSwipeVolume(deltaRatio);
    }
  }

  void pointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_cancelUntilRelease) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
      if (_pointers.isEmpty) _cancelUntilRelease = false;
      return;
    }
    if (_pointer != event.pointer || _origin == null) return;
    if (_swipeAction == SwipeAction.seek) {
      endScrub();
    } else if (_swipeAction == SwipeAction.brightness ||
        _swipeAction == SwipeAction.volume) {
      _scheduleDismissHud();
    }

    if (_moved || _held) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _pointer = null;
    _origin = null;
    _endHold();
  }

  void pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    cancel(resumeScrub: true);
    _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    if (_pointers.isEmpty) _cancelUntilRelease = false;
  }

  void _showHud(SwipeAction action, double value) {
    if (_disposed) return;
    _hudTimer?.cancel();
    _hudState = GestureHudState(type: action, value: value);
    notifyListeners();
  }

  void _scheduleDismissHud() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 1000), () {
      if (_disposed) return;
      _hudState = const GestureHudState();
      notifyListeners();
    });
  }

  void doubleTap(double x, double width, {required bool mobile}) {
    if (!available() || suppressTap || _scrubbing) return;
    if (mobile && width > 0 && x < width / 3) {
      seek(-(seekStepSeconds?.call() ?? 10));
    } else if (mobile && width > 0 && x > width * 2 / 3) {
      seek(seekStepSeconds?.call() ?? 10);
    } else {
      onTogglePlayback();
    }
  }

  void beginScrub() {
    if (_disposed ||
        _scrubbing ||
        !available() ||
        player.state.duration <= Duration.zero)
      return;
    _endHold();
    _scrubbing = true;
    _scrubEnding = false;
    _previewQueued = false;
    _resumeAfterScrub = player.state.playing;
    _scrubTarget = _scrubStart = player.state.position;
    final ticket = ++_scrubSequence;
    _scrubOperations = _scrubOperations
        .catchError((Object _) {})
        .then((_) async {
          if (!_disposed && ticket == _scrubSequence && available()) {
            await player.pause();
          }
        })
        .catchError((Object _) {
          if (!_disposed && ticket == _scrubSequence) {
            cancel();
            hint('进度预览失败，请重试');
          }
        });
    notifyListeners();
  }

  void updateScrub(Duration target) {
    if (_disposed || !_scrubbing || _scrubEnding) return;
    _scrubTarget = Duration(
      milliseconds: target.inMilliseconds.clamp(
        0,
        player.state.duration.inMilliseconds,
      ),
    );
    notifyListeners();
    _previewTimer ??= Timer(const Duration(milliseconds: 120), () {
      _previewTimer = null;
      if (_previewQueued || !_scrubbing || _scrubEnding) return;
      _previewQueued = true;
      final ticket = _scrubSequence;
      _scrubOperations = _scrubOperations
          .catchError((Object _) {})
          .then((_) async {
            if (_disposed || ticket != _scrubSequence) return;
            _previewQueued = false;
            final target = _scrubTarget;
            if (!_scrubEnding && available() && target != null) {
              await (onSeek ?? player.seek)(target);
            }
          })
          .catchError((Object _) {
            if (!_disposed && ticket == _scrubSequence) hint('预览暂不可用，松开后跳转');
          });
    });
  }

  void endScrub() {
    if (_disposed || !_scrubbing || _scrubEnding) return;
    _previewTimer?.cancel();
    _previewTimer = null;
    _scrubEnding = true;
    final ticket = _scrubSequence;
    final target = _scrubTarget;
    _scrubOperations = _scrubOperations.catchError((Object _) {}).then((
      _,
    ) async {
      if (_disposed || ticket != _scrubSequence) return;
      try {
        if (!available()) return;
        if (target != null) await (onSeek ?? player.seek)(target);
        if (!_disposed &&
            ticket == _scrubSequence &&
            available() &&
            _resumeAfterScrub) {
          await player.play();
        }
      } catch (_) {
        if (!_disposed && ticket == _scrubSequence) hint('跳转失败，请重试');
      } finally {
        if (!_disposed && ticket == _scrubSequence) {
          _scrubbing = _scrubEnding = false;
          _scrubTarget = null;
          notifyListeners();
        }
      }
    });
  }

  void seek(int seconds) {
    if (!available() || _scrubbing || player.state.duration <= Duration.zero)
      return;
    _endHold();
    final target = (player.state.position.inMilliseconds + seconds * 1000)
        .clamp(0, player.state.duration.inMilliseconds);
    unawaited((onSeek ?? player.seek)(Duration(milliseconds: target)));
    hint('${seconds > 0 ? '快进至' : '后退至'} ${formatPosition(target / 1000)}');
  }

  void changeVolume(double delta) {
    if (!available()) return;
    if (AppDevice.supportsMediaVolume) {
      unawaited(_changeSystemVolume(delta: delta));
      return;
    }
    final volume = (player.state.volume + delta).clamp(0.0, 100.0);
    _setVolume(volume, hud: false);
  }

  void toggleMute() {
    if (!available()) return;
    if (AppDevice.supportsMediaVolume) {
      unawaited(_changeSystemVolume(mute: true));
      return;
    }
    final current = player.state.volume;
    if (current > 0) _unmutedVolume = current;
    final target = current > 0 ? 0.0 : _unmutedVolume;
    _setVolume(target, hud: false);
  }

  Future<void> _changeSystemVolume({
    double delta = 0,
    bool mute = false,
  }) async {
    try {
      final current = await AppDevice.getMediaVolume();
      if (_disposed || !available()) return;
      _systemVolumeChanged(current);
      final volume = current * 100;
      final target = mute
          ? volume > 0
                ? 0.0
                : _unmutedVolume
          : (volume + delta).clamp(0.0, 100.0);
      _setVolume(target, hud: false);
    } catch (error) {
      _volumeFailed(error);
    }
  }

  KeyEventResult key(KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if (key == LogicalKeyboardKey.arrowRight && _keyboardHold) {
        _endHold(tap: available());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final hardware = HardwareKeyboard.instance;
    if (hardware.isAltPressed ||
        hardware.isMetaPressed ||
        hardware.isShiftPressed) {
      cancel();
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.f11 || key == LogicalKeyboardKey.keyF) {
      if (event is KeyDownEvent) {
        cancel();
        onFullscreen();
      }
      return KeyEventResult.handled;
    }
    if (hardware.isControlPressed || !available()) {
      return KeyEventResult.ignored;
    }
    if (key != LogicalKeyboardKey.arrowRight) _endHold();
    if (key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyDownEvent) _beginHold(keyboard: true);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      seek(-5);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      changeVolume(5);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      changeVolume(-5);
    } else if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (event is KeyDownEvent) onTogglePlayback();
    } else if (key == LogicalKeyboardKey.keyM) {
      if (event is KeyDownEvent) toggleMute();
    } else if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (event is KeyDownEvent) {
        hint(onEpisode(key == LogicalKeyboardKey.mediaTrackNext ? 1 : -1));
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _disposed = true;
    _volumeGesture++;
    _pendingSystemVolume = null;
    _mediaVolumeSubscription?.cancel();
    _holdTimer?.cancel();
    _hintTimer?.cancel();
    _hudTimer?.cancel();
    _previewTimer?.cancel();
    _scrubSequence++;
    AppDevice.resetBrightness(); // 离开播放器时自动恢复手机/平板系统默认亮度
    if (_boosting) unawaited(_setRate(baseSpeed()));
    _boosting = false;
    _playing.cancel();
    _pointers.clear();
    super.dispose();
  }
}
