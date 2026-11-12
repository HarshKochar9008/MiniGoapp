import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// What the craft screen's slot machine is doing, for its sounds.
enum OnbSoundCue {
  /// The lever was pulled.
  leverPull,

  /// The reels started rolling while the code is fetched.
  reelsSpin,

  /// The code arrived: the reels start slowing down onto it.
  reelsLand,

  /// The reels stopped without landing (crafting failed).
  reelsStop,

  /// The last tile settled on the code.
  codeReveal,
}

/// The slot machine's sounds: the lever, the reels rolling, each reel
/// stopping, and a chime for the code.
///
/// The files in `assets/sounds/` are synthesised by
/// `tool/make_onb_sounds.py` and timed to OnbSlotMachine's lever and reel
/// motion: `reels_land.wav` hits each reel's stop, so it has to be
/// regenerated if those timings change.
///
/// They play as UI sounds, not media: silent with the iOS silent switch or
/// an Android ringer on silent/vibrate, and they never pause music that is
/// already playing.
abstract final class OnbSounds {
  /// The loop starts just after the lever's clunk rather than under it, so
  /// the two don't pile up, and swells in as the reels come up to speed.
  static const _spinDelay = Duration(milliseconds: 260);

  /// The landing track opens with the same rattle as the loop, so the loop
  /// is cut just after it starts, where the cut can't be heard.
  static const _handoff = Duration(milliseconds: 40);

  static final _players = <_Sfx, Future<AudioPlayer>>{};
  static Timer? _spinStart;
  static Timer? _spinCut;

  static final _context = AudioContext(
    iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
    android: const AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.assistanceSonification,
      audioFocus: AndroidAudioFocus.none,
    ),
  );

  /// Loads every sound ahead of time so the first pull isn't late.
  static Future<void> preload() async {
    for (final sfx in _Sfx.values) {
      try {
        await _load(sfx);
      } catch (e) {
        if (kDebugMode) debugPrint('onboarding: ${sfx.file} failed: $e');
      }
    }
  }

  static Future<void> play(OnbSoundCue cue) async {
    switch (cue) {
      case OnbSoundCue.leverPull:
        await _start(_Sfx.lever);
      case OnbSoundCue.reelsSpin:
        _spinCut?.cancel();
        _spinStart?.cancel();
        _spinStart = Timer(_spinDelay, () => _fadeIn(_Sfx.spin));
      case OnbSoundCue.reelsLand:
        _spinStart?.cancel();
        await _start(_Sfx.land);
        _spinCut?.cancel();
        _spinCut = Timer(_handoff, () => _stop(_Sfx.spin));
      case OnbSoundCue.reelsStop:
        _spinStart?.cancel();
        await _fadeOut(_Sfx.spin);
      case OnbSoundCue.codeReveal:
        await _start(_Sfx.reveal);
    }
  }

  static Future<void> dispose() async {
    _spinStart?.cancel();
    _spinCut?.cancel();
    final players = [..._players.values];
    _players.clear();
    for (final pending in players) {
      try {
        await (await pending).dispose();
      } catch (_) {}
    }
  }

  /// Plays from the start. Always stops first: low-latency players on
  /// Android don't report finishing, and resuming a finished one is silent.
  static Future<void> _start(_Sfx sfx) async {
    try {
      final player = await _load(sfx);
      await player.stop();
      await player.resume();
    } catch (e) {
      if (kDebugMode) debugPrint('onboarding: ${sfx.file} failed: $e');
    }
  }

  /// Plays from the start, swelling in rather than starting at full volume.
  static Future<void> _fadeIn(_Sfx sfx) async {
    try {
      final player = await _load(sfx);
      await player.stop();
      await player.setVolume(0.4);
      await player.resume();
      for (final volume in const [0.7, 1.0]) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await player.setVolume(volume);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('onboarding: ${sfx.file} failed: $e');
    }
  }

  static Future<void> _stop(_Sfx sfx) async {
    try {
      await (await _players[sfx])?.stop();
    } catch (_) {}
  }

  /// A short fade rather than a cut, for when nothing covers the stop.
  static Future<void> _fadeOut(_Sfx sfx) async {
    try {
      final player = await _players[sfx];
      if (player == null || player.state != PlayerState.playing) return;
      for (final volume in const [0.6, 0.3, 0.1]) {
        await player.setVolume(volume);
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      await player.stop();
      await player.setVolume(1);
    } catch (_) {}
  }

  static Future<AudioPlayer> _load(_Sfx sfx) {
    final pending = _players[sfx];
    if (pending != null) return pending;
    final created = _players[sfx] = _create(sfx);
    // A failed load is retried on the next call.
    created.then((_) {}, onError: (Object _) {
      if (identical(_players[sfx], created)) _players.remove(sfx);
    });
    return created;
  }

  static Future<AudioPlayer> _create(_Sfx sfx) async {
    // Set globally first: on iOS the audio session is app-wide, and on
    // Android new players take the global context.
    await AudioPlayer.global.setAudioContext(_context);
    final player = AudioPlayer();
    try {
      await player.setPlayerMode(PlayerMode.lowLatency);
      await player.setReleaseMode(
          sfx == _Sfx.spin ? ReleaseMode.loop : ReleaseMode.stop);
      await player.setSource(AssetSource('sounds/${sfx.file}'));
      return player;
    } catch (_) {
      await player.dispose();
      rethrow;
    }
  }
}

enum _Sfx {
  lever('lever_pull.wav'),
  spin('reels_spin.wav'),
  land('reels_land.wav'),
  reveal('code_reveal.wav');

  final String file;
  const _Sfx(this.file);
}
