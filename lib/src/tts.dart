part of nondesu;

/// TTS設定（JSONの "tts" ブロック）
class TtsSettings {
  final bool enabled;
  final String provider; // "aivis_speech" | "gemini" | ...
  final double outputVolume; // 0.0..1.0

  final AivisSpeechSettings aivis;
  final Map<String, int> voiceByMascotId; // optional: mascot_id -> style_id

  const TtsSettings({
    required this.enabled,
    required this.provider,
    required this.outputVolume,
    required this.aivis,
    required this.voiceByMascotId,
  });

  factory TtsSettings.disabled() => TtsSettings(
        enabled: false,
        provider: "none",
        outputVolume: 0.2,
        aivis: const AivisSpeechSettings(),
        voiceByMascotId: const {},
      );

  factory TtsSettings.fromConfigJson(Map<String, dynamic> cfgJson) {
    final obj = (cfgJson["tts"] is Map) ? (cfgJson["tts"] as Map) : const {};

    double readDouble(String k, double def) {
      final v = obj[k];
      if (v is double) return v;
      if (v is int) return v.toDouble();
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v.trim()) ?? def;
      return def;
    }

    double clamp01(double x) => x < 0 ? 0 : (x > 1 ? 1 : x);

    bool readBool(String k, bool def) {
      final v = obj[k];
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final s = v.trim().toLowerCase();
        if (s == "true" || s == "1" || s == "yes" || s == "on") return true;
        if (s == "false" || s == "0" || s == "no" || s == "off") return false;
      }
      return def;
    }

    String readString(String k, String def) => (obj[k] ?? def).toString();

    Map<String, int> readVoiceMap() {
      final m = <String, int>{};
      final raw = obj["voice_by_mascot_id"];
      if (raw is Map) {
        for (final e in raw.entries) {
          final key = e.key.toString();
          final v = e.value;
          if (v is int) m[key] = v;
          else if (v is num) m[key] = v.toInt();
          else if (v is String) m[key] = int.tryParse(v.trim()) ?? 0;
        }
        m.removeWhere((k, v) => v == 0);
      }
      return m;
    }

    final aivisObj = (obj["aivis_speech"] is Map) ? (obj["aivis_speech"] as Map) : const {};
    return TtsSettings(
      enabled: readBool("enabled", false),
      provider: readString("provider", "aivis_speech").trim(),
      outputVolume: clamp01(readDouble("output_volume", 0.2)),
      aivis: AivisSpeechSettings.fromJson(aivisObj),
      voiceByMascotId: readVoiceMap(),
    );
  }
}

class AivisSpeechSettings {
  final String baseUrl; // e.g. http://127.0.0.1:10101
  final int defaultStyleId; // /speakers の style_id
  final bool useCancellableSynthesis; // /cancellable_synthesis を使うか（Engine起動オプションが必要）

  // AudioQueryの上書き（必要最小限で）
  final double? speedScale;
  final double? pitchScale;
  final double? intonationScale;
  final double? volumeScale;
  final double? tempoDynamicsScale;

  const AivisSpeechSettings({
    this.baseUrl = "http://127.0.0.1:10101",
    this.defaultStyleId = 0,
    this.useCancellableSynthesis = false,
    this.speedScale,
    this.pitchScale,
    this.intonationScale,
    this.volumeScale,
    this.tempoDynamicsScale,
  });

  factory AivisSpeechSettings.fromJson(Map obj) {
    String readString(String k, String def) => (obj[k] ?? def).toString();

    int readInt(String k, int def) {
      final v = obj[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim()) ?? def;
      return def;
    }

    bool readBool(String k, bool def) {
      final v = obj[k];
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final s = v.trim().toLowerCase();
        if (s == "true" || s == "1" || s == "yes" || s == "on") return true;
        if (s == "false" || s == "0" || s == "no" || s == "off") return false;
      }
      return def;
    }

    double? readDoubleNullable(String k) {
      final v = obj[k];
      if (v == null) return null;
      if (v is double) return v;
      if (v is int) return v.toDouble();
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v.trim());
      return null;
    }

    return AivisSpeechSettings(
      baseUrl: readString("base_url", "http://127.0.0.1:10101"),
      defaultStyleId: readInt("default_style_id", 0),
      useCancellableSynthesis: readBool("use_cancellable_synthesis", false),
      speedScale: readDoubleNullable("speedScale"),
      pitchScale: readDoubleNullable("pitchScale"),
      intonationScale: readDoubleNullable("intonationScale"),
      volumeScale: readDoubleNullable("volumeScale"),
      tempoDynamicsScale: readDoubleNullable("tempoDynamicsScale"),
    );
  }
}

class TtsClip {
  final Uint8List wavBytes;
  final Duration? duration;

  const TtsClip(this.wavBytes, {this.duration});
}

class TtsManager {
  final TtsSettings settings;
  final http.Client _http;
  final AudioPlayer _player;

  File? _tmpFile;
  String? lastError;

  TtsManager._(this.settings, this._http, this._player);

  factory TtsManager.fromConfigJson(Map<String, dynamic> cfgJson) {
    final s = TtsSettings.fromConfigJson(cfgJson);
    return TtsManager._(s, http.Client(), AudioPlayer());
  }

  bool get enabled => settings.enabled;

  int _styleIdForMascot(String? mascotId) {
    if (mascotId != null) {
      final v = settings.voiceByMascotId[mascotId];
      if (v != null && v != 0) return v;
    }
    return settings.aivis.defaultStyleId;
  }

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
    try {
      final f = _tmpFile;
      _tmpFile = null;
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  void dispose() {
    _http.close();
    _player.dispose();
    try {
      final f = _tmpFile;
      _tmpFile = null;
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 合成だけ先に行う（口パク前の“仕込み”）
  Future<TtsClip?> synthesize(String text, {String? mascotId}) async {
    lastError = null;
    if (!enabled) return null;

    final provider = settings.provider.trim().toLowerCase();
    if (provider != "aivis_speech") return null;

    final a = settings.aivis;
    final styleId = _styleIdForMascot(mascotId);
    if (styleId == 0) {
      lastError = "AivisSpeech: style_id が未設定（tts.aivis_speech.default_style_id）";
      return null;
    }

    try {
      final base = Uri.parse(a.baseUrl);

      // /audio_query?speaker={style_id}&text=...
      final aqUri = base.replace(
        path: "/audio_query",
        queryParameters: {
          "speaker": styleId.toString(),
          "text": text,
        },
      );

      final aqResp = await _http.post(aqUri);
      if (aqResp.statusCode != 200) {
        lastError = "AivisSpeech /audio_query failed: ${aqResp.statusCode}";
        return null;
      }

      final audioQuery = jsonDecode(utf8.decode(aqResp.bodyBytes));
      if (audioQuery is! Map) {
        lastError = "AivisSpeech /audio_query: invalid json";
        return null;
      }

      // 重要: まずは必要最小限の上書きだけ（仕様差分があるため） :contentReference[oaicite:3]{index=3}
      void maybeSet(String k, double? v) {
        if (v == null) return;
        audioQuery[k] = v;
      }

      maybeSet("speedScale", a.speedScale);
      maybeSet("pitchScale", a.pitchScale);
      maybeSet("intonationScale", a.intonationScale);
      maybeSet("volumeScale", a.volumeScale);
      maybeSet("tempoDynamicsScale", a.tempoDynamicsScale);

      // /synthesis or /cancellable_synthesis
      final synthPath = a.useCancellableSynthesis ? "/cancellable_synthesis" : "/synthesis";
      final synUri = base.replace(
        path: synthPath,
        queryParameters: {"speaker": styleId.toString()},
      );

      final synResp = await _http.post(
        synUri,
        headers: const {"Content-Type": "application/json"},
        body: jsonEncode(audioQuery),
      );

      if (synResp.statusCode != 200) {
        lastError = "AivisSpeech $synthPath failed: ${synResp.statusCode}";
        return null;
      }

      final bytes = synResp.bodyBytes;
      return TtsClip(bytes, duration: _tryParseWavDuration(bytes));
    } catch (e) {
      lastError = "AivisSpeech synthesize error: $e";
      return null;
    }
  }

  /// 合成 → 再生（再生直前コールバックで口パク開始しやすい）
  Future<bool> speak(
    String text, {
    String? mascotId,
    void Function()? onAudioStart,
    void Function()? onAudioDone,
  }) async {
    final clip = await synthesize(text, mascotId: mascotId);
    if (clip == null) return false;

    try {
      await stop(); // 前の音声が残ってたら消す

      final dir = await getTemporaryDirectory();
      final fn = "nondesu_tts_${DateTime.now().microsecondsSinceEpoch}.wav";
      final f = File(p.join(dir.path, fn));
      await f.writeAsBytes(clip.wavBytes, flush: true);
      _tmpFile = f;

      onAudioStart?.call();

      // Volume
      await _player.setVolume(settings.outputVolume);
      // AivisSpeechは 24000Hz WAV の場合があり、プレーヤーによっては再生できないことがある :contentReference[oaicite:4]{index=4}
      // OS側デコーダに任せるためファイル再生に寄せる
      await _player.play(DeviceFileSource(f.path));

      final done = Completer<void>();
      late final StreamSubscription sub;
      sub = _player.onPlayerComplete.listen((_) async {
        await sub.cancel();
        done.complete();
      });
      await done.future;

      onAudioDone?.call();
      return true;
    } catch (e) {
      lastError = "playback error: $e";
      return false;
    } finally {
      try {
        final f = _tmpFile;
        _tmpFile = null;
        if (f != null && f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  /// WAV durationを雑に取る（口パク停止の保険に使える）
  Duration? _tryParseWavDuration(Uint8List wav) {
    try {
      if (wav.length < 44) return null;
      // RIFF....WAVE は前提、data chunk を探す
      int idx = 12;
      int? byteRate;
      int? dataSize;

      while (idx + 8 <= wav.length) {
        final chunkId = ascii.decode(wav.sublist(idx, idx + 4));
        final chunkSize = _le32(wav, idx + 4);
        idx += 8;

        if (chunkId == "fmt ") {
          // byteRate at offset 8
          if (idx + 12 <= wav.length) {
            byteRate = _le32(wav, idx + 8);
          }
        } else if (chunkId == "data") {
          dataSize = chunkSize;
          break;
        }

        idx += chunkSize;
        if (idx.isOdd) idx += 1; // padding
      }

      if (byteRate == null || dataSize == null || byteRate <= 0) return null;
      final seconds = dataSize / byteRate;
      final ms = (seconds * 1000).round();
      return Duration(milliseconds: ms);
    } catch (_) {
      return null;
    }
  }

  int _le32(Uint8List b, int o) =>
      (b[o]) | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
}
