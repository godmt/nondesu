part of nondesu;

// ===== Home =====

class MascotHome extends StatefulWidget {
  const MascotHome({super.key});

  @override
  State<MascotHome> createState() => _MascotHomeState();
}

class _MascotHomeState extends State<MascotHome> with WindowListener {
  MascotPack? _pack;
  String? _selectedMascotId;
  AppConfig? _config;
  String? _configPath;
  final Map<String, _RgbaMask> _maskCache = {};

  // State
  MascotTurn? _turn;
  bool _mouthOpen = false;
  Timer? _idleTimer;
  Timer? _mouthTimer;
  bool _quiet = false;
  DateTime? _quietUntil;

  _DedupeState _dedupe = _DedupeState([]);
  String? _statePath;
  static const String _stateFileName = "nondesu_state.json";

  // rss
  static const String _rssSettingsFileName = "rss_feeds.json";
  static const String _rssCacheFileName = "rss_cache.json";
  static const String _rssStateFileName = "rss_state.json";
  RssState _rssState = RssState.empty();
  String? _lastOpenLinkUrl; // 直近の「元記事」URL（rss talkでセット）

  RssSettings? _rssSettings;
  RssCache _rssCache = RssCache([]);

  // GeminiBusy flag and Speech bubble
  bool _bubbleVisible = true;
  String? _bubbleContextTitle;
  bool _isGeminiBusy = false;
  Timer? _autoCloseBubbleTimer;

  void _showBubble() {
    if (!_bubbleVisible) setState(() => _bubbleVisible = true);
  }

  void _closeBubbleNow() {
    _autoCloseBubbleTimer?.cancel();
    if (_bubbleVisible) setState(() => _bubbleVisible = false);
  }

  void _autoCloseBubble([Duration d = const Duration(milliseconds: 1400)]) {
    _autoCloseBubbleTimer?.cancel();
    _autoCloseBubbleTimer = Timer(d, () {
      if (mounted) setState(() => _bubbleVisible = false);
    });
  }

  void _setGeminiBusy(bool v) {
    if (_isGeminiBusy == v) return;
    setState(() => _isGeminiBusy = v);
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _boot();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _mouthTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _boot() async {
    // 1) config json (gemini key may be missing, but we still want avatar selection)
    final cfgJson = await _loadConfigJson();

    // 2) choose avatar
    final selectedId = (cfgJson["selected_mascot_id"] ?? "").toString().trim();
    final pack = await _loadMascotPackByIdOrFirst(selectedId.isEmpty ? null : selectedId);
    if (pack == null) {
      setState(() {
        _turn = MascotTurn.fallback("avatarsが見つからない。…配置、お願い。");
      });
      return;
    }

    _pack = pack;
    _selectedMascotId = pack.id;

    // 3) parse app config (may be null until user pastes the key)
    _config = _parseAppConfig(cfgJson);
    if (_config == null) {
      setState(() {
        _turn = MascotTurn.fallback("設定ファイルが未設定。\n$_configFileName を編集して再起動して。");
      });
      // ここで return しても良いが、アバター表示だけ先に見たいなら return しない
      // return;
    }
    // rss
    _rssSettings = await _loadRssSettings();
    await _loadRssCache();
    await _loadRssState();

    if (_rssSettings?.fetchOnStart == true) {
      await _fetchRssOnce(); // エラーはUIとログに出る設計
    }
    // dedupe state
    await _loadDedupeState();
    await windowManager.setSize(pack.windowSize);
    _scheduleNextIdle();
    setState(() {});
  }

  Future<void> _showContextMenu(Offset globalPos) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx, globalPos.dy, globalPos.dx, globalPos.dy,
      ),
      items: const [
        PopupMenuItem(value: "avatar", child: Text("アバター変更")),
        PopupMenuItem(value: "talk_rss", child: Text("RSS 未読を話す")),
        PopupMenuItem(value: "update_rss", child: Text("RSS更新")),
        PopupMenuItem(value: "exit", child: Text("終了")),
      ],
    );

    if (selected == "exit") {
      await windowManager.close();
    } else if (selected == "avatar") {
      await _openAvatarPicker();
    } else if (selected == "update_rss") {
      await _fetchRssOnce();
    } else if (selected == "talk_rss") {
      await _doGeminiRssTalk();
    }
  }

  Future<void> _openAvatarPicker() async {
    final currentPack = _pack;
    if (currentPack == null) return;

    final oldSize = await windowManager.getSize();
    const pickerSize = Size(600, 720);
    await windowManager.setSize(pickerSize);
    await windowManager.center();

    final avatars = await _scanAvatarSummaries();
    if (!mounted) return;

    final picked = await showDialog<_AvatarSummary>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      builder: (context) {
        final base = Theme.of(context);
        return Theme(
          data: base.copyWith(
            brightness: Brightness.dark,
            // ダイアログ背景
            dialogTheme: const DialogThemeData(
              backgroundColor: Color(0xFF14161A),
              surfaceTintColor: Colors.transparent, // Material3の薄い色被りを消す
            ),
            // 文字色（タイトル/本文）
            textTheme: base.textTheme.apply(
              bodyColor: Colors.white,
              displayColor: Colors.white,
            ),
            // ダイアログ内のボタン色
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
              ),
            ),
          ),
          child: _AvatarPickerDialog(
            avatars: avatars,
            selectedId: _pack?.id,
          ),
        );
      },
    );

    if (picked == null) {
      // restore
      await windowManager.setSize(oldSize);
      await windowManager.center();
      return;
    }

    await _switchMascot(picked);
  }

  Future<void> _switchMascot(_AvatarSummary picked) async {
    try {
      final newPack = await _loadMascotPack(picked.dir);
      _maskCache.clear();
      _mouthTimer?.cancel();
      _mouthTimer = null;
      _mouthOpen = false;

      setState(() {
        _pack = newPack;
        _selectedMascotId = newPack.id;
        _turn = MascotTurn.fallback("…${newPack.name} に切り替えた");
      });

      await _setConfigSelectedMascotId(newPack.id);
      await windowManager.setSize(newPack.windowSize);
      await windowManager.center();
      await windowManager.focus();
    } catch (e, st) {
      await _logEvent("error", {
        "where": "avatar_switch",
        "error": _trimForLog(e.toString()),
        "stack": _trimForLog(st.toString()),
        "picked": picked.id,
      });
      if (!mounted) return;
      setState(() {
        _turn = MascotTurn.fallback("アバター切替エラー: ${picked.id}");
      });
    }
  }

  Future<void> _maybeStartDrag(Offset localPos) async {
    final pack = _pack;
    final turn = _turn;
    if (pack == null) return;

    final emotion = turn?.emotion ?? pack.defaultEmotion;
    final sprite = pack.sprites[emotion];
    final maskPath = sprite?.closedPath; // 口パクしても判定は閉じ画像で十分実用
    if (maskPath == null) return;

    _maskCache[maskPath] ??= (await _loadRgbaMask(maskPath)) ?? _maskCache[maskPath]!;
    final mask = _maskCache[maskPath];
    if (mask == null) return;

    final winSize = MediaQuery.sizeOf(context);
    final ok = _isOpaqueAtContainFit(local: localPos, widgetSize: winSize, mask: mask);

    if (ok) {
      await windowManager.startDragging(); // :contentReference[oaicite:8]{index=8}
    }
  }

  Future<List<Directory>> _listMascotDirs() async {
    final baseDir = await _resolveBaseDir();
    final avatarsDir = Directory(p.join(baseDir.path, "avatars"));
    if (!avatarsDir.existsSync()) return const [];
    final children = avatarsDir
        .listSync()
        .whereType<Directory>()
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return children;
  }

  Future<MascotPack?> _loadMascotPackByIdOrFirst(String? id) async {
    final dirs = await _listMascotDirs();
    if (dirs.isEmpty) return null;

    String? _thumbAbsFromManifest(Map manifest, Directory dir) {
      final thumbRel = (manifest["thumbnail"] as String?)?.trim();
      if (thumbRel == null || thumbRel.isEmpty) return null;
      final abs = p.join(dir.path, thumbRel);
      if (!File(abs).existsSync()) return null;
      return abs;
    }

    if (id != null && id.trim().isNotEmpty) {
      final wanted = id.trim();
      for (final d in dirs) {
        try {
          final mf = File(p.join(d.path, "manifest.json"));
          if (!mf.existsSync()) continue;
          final m = jsonDecode(await mf.readAsString());
          if (m is! Map) continue;
          final mid = (m["id"] ?? p.basename(d.path)).toString();
          if (mid == wanted) {
            // thumbnail is mandatory
            if (_thumbAbsFromManifest(m, d) == null) continue;
            return _loadMascotPack(d);
          }
        } catch (_) {
          // ignore
        }
      }
      // fallback: directory name match
      for (final d in dirs) {
        if (p.basename(d.path) == wanted) {
          try {
            final mf = File(p.join(d.path, "manifest.json"));
            if (!mf.existsSync()) continue;
            final m = jsonDecode(await mf.readAsString());
            if (m is! Map) continue;
            if (_thumbAbsFromManifest(m, d) == null) continue;
            return _loadMascotPack(d);
          } catch (_) {
            // ignore
          }
        }
      }
    }

    // pick first valid mascot (thumbnail must exist)
    for (final d in dirs) {
      try {
        final mf = File(p.join(d.path, "manifest.json"));
        if (!mf.existsSync()) continue;
        final m = jsonDecode(await mf.readAsString());
        if (m is! Map) continue;
        if (_thumbAbsFromManifest(m, d) == null) continue;
        return _loadMascotPack(d);
      } catch (_) {
        // ignore
      }
    }
    return null;
  }

  Future<List<_AvatarSummary>> _scanAvatarSummaries() async {
    final dirs = await _listMascotDirs();
    final out = <_AvatarSummary>[];
    for (final d in dirs) {
      try {
        final mf = File(p.join(d.path, "manifest.json"));
        if (!mf.existsSync()) continue;
        final j = jsonDecode(await mf.readAsString());
        if (j is! Map) continue;
        final manifest = j as Map;

        final id = (manifest["id"] ?? p.basename(d.path)).toString();
        final name = (manifest["name"] ?? id).toString();
        final description = (manifest["description"] ?? "").toString();

        final window = (manifest["window"] as Map?) ?? const {};
        final width = (window["width"] as num?)?.toDouble() ?? 256.0;
        final height = (window["height"] as num?)?.toDouble() ?? 256.0;

        // thumbnail is mandatory
        final thumbRel = (manifest["thumbnail"] as String?)?.trim();
        if (thumbRel == null || thumbRel.isEmpty) {
          await _logEvent("error", {
            "where": "avatar_scan",
            "dir": d.path,
            "error": "manifest.thumbnail is required",
          });
          continue;
        }
        final thumbAbs = p.join(d.path, thumbRel);
        if (!File(thumbAbs).existsSync()) {
          await _logEvent("error", {
            "where": "avatar_scan",
            "dir": d.path,
            "error": "thumbnail file not found: $thumbRel",
          });
          continue;
        }

        out.add(_AvatarSummary(
          id: id,
          name: name,
          description: description,
          dir: d,
          thumbnailPath: thumbAbs,
          windowSize: Size(width, height),
        ));
      } catch (e, st) {
        await _logEvent("error", {
          "where": "avatar_scan",
          "dir": d.path,
          "error": _trimForLog(e.toString()),
          "stack": _trimForLog(st.toString()),
        });
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  Future<MascotPack> _loadMascotPack(Directory mascotDir) async {
    final manifestFile = File(p.join(mascotDir.path, "manifest.json"));
    if (!await manifestFile.exists()) {
      throw Exception("manifest.json not found in ${mascotDir.path}");
    }

    final manifest = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;

    final id = (manifest["id"] as String?) ?? p.basename(mascotDir.path);
    final name = (manifest["name"] as String?) ?? id;

    // window
    final window = (manifest["window"] as Map?) ?? const {};
    final width = (window["width"] as num?)?.toDouble() ?? 256.0;
    final height = (window["height"] as num?)?.toDouble() ?? 256.0;

    // character prompt (user editable)
    final characterPromptFile = File(p.join(mascotDir.path, "character_prompt.txt"));
    final legacySystemPromptFile = File(p.join(mascotDir.path, "system_prompt.txt")); // back-compat
    String characterPrompt = "";
    if (await characterPromptFile.exists()) {
      characterPrompt = await characterPromptFile.readAsString();
    } else if (await legacySystemPromptFile.exists()) {
      characterPrompt = await legacySystemPromptFile.readAsString();
    }

    final systemPrompt = _buildSystemPromptV1(characterPrompt);

    // sprites (emotion id -> {closed/open})
    final sprites = <EmotionId, SpritePair>{};
    final spritesJson = manifest["sprites"];
    if (spritesJson is Map) {
      for (final e in spritesJson.entries) {
        final rawKey = e.key.toString().trim();
        if (rawKey.isEmpty) continue;
        final key = rawKey.toLowerCase();
        if (e.value is! Map) continue;
        final m = e.value as Map;
        final closedRel = (m["closed"] ?? "").toString();
        final openRel = (m["open"] ?? "").toString();
        if (closedRel.isEmpty || openRel.isEmpty) continue;

        sprites[key] = SpritePair(
          closedPath: p.join(mascotDir.path, closedRel),
          openPath: p.join(mascotDir.path, openRel),
        );
      }
    }
    if (sprites.isEmpty) {
      throw Exception("sprites not found/empty in manifest.json (${mascotDir.path})");
    }

    EmotionId defaultEmotion =
        (manifest["default_emotion"] ?? kEmotionIdle).toString().trim().toLowerCase();
    if (!sprites.containsKey(defaultEmotion)) {
      defaultEmotion = sprites.containsKey(kEmotionIdle) ? kEmotionIdle : sprites.keys.first;
    }

    final defChoiceProfile = MascotTurn.parseChoiceProfile(
      (manifest["default_choice_profile"] ?? "idle_default").toString(),
    );

    return MascotPack(
      id: id,
      name: name,
      windowSize: Size(width, height),
      sprites: sprites,
      defaultEmotion: defaultEmotion,
      defaultChoiceProfile: defChoiceProfile,
      emotionIds: sprites.keys.toList(growable: false),
      characterPrompt: characterPrompt,
      systemPrompt: systemPrompt,
    );
  }

  Future<Directory> _resolveBaseDir() async {
    // Prefer: executable dir
    try {
      final exe = File(Platform.resolvedExecutable);
      final dir = exe.parent;
      if (Directory(p.join(dir.path, "avatars")).existsSync()) return dir;
    } catch (_) {}

    // Fallback: app support dir
    final appSupport = await getApplicationSupportDirectory();
    return appSupport;
  }

  static const String _configFileName = "nondesu_config.json";

  Future<File> _getConfigFile() async {
    // exe と同じフォルダを優先（avatars の有無には依存しない）
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      return File(p.join(exeDir.path, _configFileName));
    } catch (_) {
      final appSupport = await getApplicationSupportDirectory();
      return File(p.join(appSupport.path, _configFileName));
    }
  }

  String _trimForLog(String s, {int max = 4000}) {
    if (s.length <= max) return s;
    return "${s.substring(0, max)}…(truncated)";
  }

  Future<Map<String, dynamic>> _loadConfigJson() async {
    final f = await _getConfigFile();
    _configPath = f.path;

    final template = <String, dynamic>{
      // Gemini
      "gemini_api_key": "PASTE_YOUR_KEY_HERE",

      // Avatar selection (optional)
      "selected_mascot_id": "",

      // Talk cadence
      "idle_talk_min_sec": 30,
      "idle_talk_max_sec": 90,

      // Dedupe
      "dedupe_recent_turns": 120,
      "dedupe_hamming_threshold": 10,
      "dedupe_prompt_hints": 10,
    };

    if (!f.existsSync()) {
      await f.writeAsString(const JsonEncoder.withIndent("  ").convert(template));
      await _logEvent("config", {"status": "created_template", "path": f.path});
      return template;
    }

    try {
      final raw = await f.readAsString();
      final obj = jsonDecode(raw);
      if (obj is! Map) return template;
      // merge template defaults (missing keys only)
      final out = <String, dynamic>{...template};
      for (final e in obj.entries) {
        out[e.key.toString()] = e.value;
      }
      return out;
    } catch (e, st) {
      await _logEvent("error", {
        "where": "load_config_json",
        "error": _trimForLog(e.toString()),
        "stack": _trimForLog(st.toString()),
        "path": f.path,
      });
      return template;
    }
  }

  AppConfig? _parseAppConfig(Map<String, dynamic> obj) {
    final key = (obj["gemini_api_key"] ?? "").toString().trim();
    if (key.isEmpty || key == "PASTE_YOUR_KEY_HERE") return null;

    int readInt(String k, int def) {
      final v = obj[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim()) ?? def;
      return def;
    }

    final minSec = readInt("idle_talk_min_sec", 30);
    final maxSec = readInt("idle_talk_max_sec", 90);
    final safeMin = minSec.clamp(3, 24 * 60 * 60);
    final safeMax = maxSec.clamp(safeMin, 24 * 60 * 60);

    return AppConfig(
      geminiApiKey: key,
      idleTalkMinSec: safeMin,
      idleTalkMaxSec: safeMax,
      dedupeRecentTurns: readInt("dedupe_recent_turns", 120),
      dedupeHammingThreshold: readInt("dedupe_hamming_threshold", 10),
      dedupePromptHints: readInt("dedupe_prompt_hints", 10),
    );
  }

  Future<void> _setConfigSelectedMascotId(String id) async {
    final f = await _getConfigFile();
    final obj = await _loadConfigJson();
    obj["selected_mascot_id"] = id;
    await f.writeAsString(const JsonEncoder.withIndent("  ").convert(obj));
    await _logEvent("config", {
      "status": "updated_selected_mascot_id",
      "selected_mascot_id": id,
      "path": f.path,
    });
  }

  void _scheduleNextIdle() {
    _idleTimer?.cancel();

    if (_quietUntil != null && DateTime.now().isBefore(_quietUntil!)) {
      _quiet = true;
    } else {
      _quiet = false;
      _quietUntil = null;
    }
    if (_quiet) return;

    // Ukagaka-ish: random interval 30~90 seconds for PoC
    final cfg = _config;
    final minSec = cfg?.idleTalkMinSec ?? 30;
    final maxSec = cfg?.idleTalkMaxSec ?? 90;
    final span = max(0, maxSec - minSec);
    final sec = minSec + (span == 0 ? 0 : Random().nextInt(span + 1));

    _idleTimer = Timer(Duration(seconds: sec), () async {
      await _doGeminiIdleTalk(from: "scheduled_idle");
      _scheduleNextIdle();
    });
  }

  Future<void> _doGeminiIdleTalk({String from = "idle"}) async {
    _bubbleContextTitle = null;
    final userPrompt = _buildUserPrompt(mode: "idle", maxChars: 70);

    final t = await _requestGeminiTurn(
      where: "gemini_idle",
      mode: "idle",
      from: from,
      userPrompt: userPrompt,
    );
    if (t == null) return;

    // 重複除外チェック（あなたの既存のまま）
    final reason = _dedupeReason(t);
    if (reason != null) {
      await _logEvent("dedupe_reject", {
        "reason": reason,
        "state_path": _statePath,
        "text": _trimForLog(t.text),
        "debug_line_id": t.debugLineId,
      });

      final fallback = MascotTurn(
        v: 1,
        text: "…さっきと話題が近い。別の話にしよ。",
        emotion: kEmotionIdle,
        choiceProfile: t.choiceProfile,
        choices: t.choices,
        debugLineId: "local.dedupe.skip",
      );

      setState(() => _turn = fallback);
      _startMouthFlap();
      await _recordForDedupe(fallback);
      await _logEvent("turn", {"mode": "idle", "from": from, "turn": fallback.toLogJson()});
      return;
    }

    setState(() => _turn = t);
    _startMouthFlap();
    await _recordForDedupe(t);
    await _logEvent("turn", {"mode": "idle", "from": from, "turn": t.toLogJson()});
  }

  Future<void> _doGeminiFollowupTalk({
    required String lastIntentWire,
    String? userText,
  }) async {
    try {

    final base = _buildUserPrompt(
      mode: "followup",
      maxChars: 90,
      lastIntentWire: lastIntentWire,
      lastMascotText: _turn?.text,
      topic: null,
    );
    _bubbleContextTitle = null;
    // free input がある時だけ追記（_buildUserPromptの改造は不要）
    final userPrompt = (userText == null || userText.trim().isEmpty)
        ? base
        : "$base\nUSER_INPUT: ${userText.trim()}\n";

    final t = await _requestGeminiTurn(
      where: "gemini_followup",
      mode: "followup",
      from: "followup:$lastIntentWire",
      userPrompt: userPrompt,
    );
    if (t == null) return;

    setState(() {
      _turn = t;
      _bubbleVisible = true;
    });
    _startMouthFlap();
    await _recordForDedupe(t);
    await _logEvent("turn", {"mode": "followup", "from": "followup:$lastIntentWire", "turn": t.toLogJson()});
  
    } finally {
      // 何経由でも「喋った後」はクールダウンをリセット
      _scheduleNextIdle();
    }
}

  void _startMouthFlap() {
    _mouthTimer?.cancel();
    _mouthOpen = false;

    // Simple flap for 1.6 sec
    int ticks = 0;
    _mouthTimer = Timer.periodic(const Duration(milliseconds: 160), (timer) {
      ticks++;
      setState(() => _mouthOpen = !_mouthOpen);
      if (ticks >= 10) {
        timer.cancel();
        setState(() => _mouthOpen = false);
      }
    });
  }

  List<MascotChoice> _choicesForProfile(ChoiceProfile p) {
    switch (p) {
      case ChoiceProfile.none:
        return const [];
      case ChoiceProfile.rssDefault:
        return [
          MascotChoice(id: "c1", label: "元記事", intent: Intent.openLink),
          MascotChoice(id: "c2", label: "もう少し", intent: Intent.more),
          MascotChoice(id: "c3", label: "別の話", intent: Intent.changeTopic),
        ];
      case ChoiceProfile.inputOffer:
        return [
          MascotChoice(id: "c1", label: "入力", intent: Intent.openInput),
          MascotChoice(id: "c2", label: "別の話", intent: Intent.changeTopic),
          MascotChoice(id: "c3", label: "静かに", intent: Intent.quietMode),
        ];
      case ChoiceProfile.idleDefault:
      default:
        return [
          MascotChoice(id: "c1", label: "もう少し", intent: Intent.more),
          MascotChoice(id: "c2", label: "別の話", intent: Intent.changeTopic),
          MascotChoice(id: "c3", label: "静かに", intent: Intent.quietMode),
        ];
    }
  }

  Future<void> _onAvatarTap() async {
    // Gemini 通信中の連打は無視（多重呼び出し防止）
    if (_isGeminiBusy) return;

    try {
      // PoC: click triggers immediate talk
      await _doGeminiIdleTalk(from: "avatar_tap");
    } finally {
      // 何経由でも「喋った後」はクールダウンをリセット
      _scheduleNextIdle();
    }
  }

  Future<void> _onChoice(Intent intent) async {
    // 通信中の多重クリック防止（UI側で無効化してても保険）
    if (_isGeminiBusy) return;

    final wire = _intentToWire(intent);
    await _logEvent("choice", {"intent": wire});

    // どのボタンでも「押した瞬間」いったん閉じる
    _closeBubbleNow();

    // quiet はローカルで完結
    if (intent == Intent.quietMode) {
      _quietUntil = DateTime.now().add(const Duration(minutes: 30));
      _quiet = true;

      // 返答は短く見せてすぐ閉じる（好みで 0ms にしてもOK）
      setState(() {
        _turn = MascotTurn.fallback("…了解。しばらく静かにしてる。");
        _bubbleVisible = true;
      });
      _startMouthFlap();
      await _logEvent("turn", {
        "mode": "local",
        "from": "choice:$wire",
        "turn": (_turn ?? MascotTurn.fallback("")).toLogJson(),
      });

      _scheduleNextIdle();
      _autoCloseBubble(const Duration(milliseconds: 6500));
      _scheduleNextIdle();
        return;
    }

    // open link はローカルで完結（既定ブラウザ）
    if (intent == Intent.openLink) {
      final url = _lastOpenLinkUrl;
      if (url == null || url.trim().isEmpty) {
        setState(() {
          _turn = MascotTurn.fallback("…元記事URLが無いみたい。");
          _bubbleVisible = true;
        });
        _startMouthFlap();
        _autoCloseBubble(const Duration(milliseconds: 6500));
        return;
      }

      final ok = await _openExternalUrl(url);
      await _logEvent("open_link", {"url": url, "ok": ok});

      // 失敗時だけ短く通知（成功時は閉じるだけ）
      if (!ok) {
        setState(() {
          _turn = MascotTurn.fallback("…開けなかった。ログに残した。");
          _bubbleVisible = true;
        });
        _startMouthFlap();
        _autoCloseBubble(const Duration(milliseconds: 3000));
        _scheduleNextIdle();
        return;
      }

      // 成功したら即閉じ
      _scheduleNextIdle();
      _closeBubbleNow();
      return;
    }

    // open input は入力を取って followup へ
    if (intent == Intent.openInput) {
      final input = await _showInputDialog();
      if (input == null || input.trim().isEmpty) {
        // キャンセル時は何もしない（閉じたまま）
        return;
      }

      // 通信中の “……” を表示
      _showBubble();
      _autoCloseBubbleTimer?.cancel();
      await _doGeminiFollowupTalk(lastIntentWire: wire, userText: input);

      // 返答を少し見せて閉じる
      _autoCloseBubble(const Duration(milliseconds: 6500));
      return;
    }

    // それ以外（more/changeTopic/ok/nope）は全部 followup に統一
    _showBubble();
    _autoCloseBubbleTimer?.cancel();
    await _doGeminiFollowupTalk(lastIntentWire: wire);

    // 返答を少し見せて閉じる
    _autoCloseBubble(const Duration(milliseconds: 6500));
  }

  Future<String?> _showInputDialog() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("入力"),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(hintText: "話しかける（任意）"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("キャンセル")),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text("送る")),
        ],
      ),
    );
  }

  String? _dedupeReason(MascotTurn t) {
    final cfg = _config;
    if (cfg == null) return null;

    // debug_line_id があるなら最優先で弾く（安い）
    final id = t.debugLineId;
    if (id != null && id.isNotEmpty) {
      for (final e in _dedupe.recent) {
        if (e.debugLineId == id) return "debug_line_id_dup";
      }
    }

    // text fingerprint
    final th = "sha256:${sha256.convert(utf8.encode(t.text)).toString()}";
    final sh = _simhash64(t.text);

    for (final e in _dedupe.recent) {
      if (e.textHash == th) return "exact_text_hash_dup";
      final prev = _parseHex64(e.simhashHex);
      final d = _hamming64(sh, prev);
      if (d <= cfg.dedupeHammingThreshold) {
        return "simhash_near_dup(d=$d)";
      }
    }
    return null;
  }

  Future<void> _recordForDedupe(MascotTurn t) async {
    final cfg = _config;
    if (cfg == null) return;

    final th = "sha256:${sha256.convert(utf8.encode(t.text)).toString()}";
    final sh = _hex64(_simhash64(t.text));
    final entry = _DedupeEntry(
      ts: DateTime.now().toIso8601String(),
      textHash: th,
      simhashHex: sh,
      debugLineId: t.debugLineId,
      hint: _hintOf(t.text),
    );

    _dedupe.recent.add(entry);

    final f = await _getStateFile();
    final maxEntries = cfg.dedupeRecentTurns;
    await _dedupe.save(f, maxEntries: maxEntries);
  }

  // ===== Minimal logger (very small) =====

  Future<void> _logEvent(String type, Map<String, dynamic> data) async {
    try {
      final logsDir = await _getLogsDir();

      final day = DateTime.now();
      final fn = "${day.year.toString().padLeft(4, '0')}"
          "${day.month.toString().padLeft(2, '0')}"
          "${day.day.toString().padLeft(2, '0')}.jsonl";
      final f = File(p.join(logsDir.path, fn));

      // Hard cap to prevent bloat: stop logging if file > 256KB
      if (f.existsSync() && f.lengthSync() > 256 * 1024) return;

      final payload = {
        "ts": DateTime.now().toIso8601String(),
        "type": type,
        "mascot": _pack?.id,
        "data": data,
      };

      await f.writeAsString("${jsonEncode(payload)}\n", mode: FileMode.append, flush: false);
    } catch (_) {
      // ログが書けない状況では諦める（UIは別途エラー表示する方針なのでOK）
    }
  }

  Future<Directory> _getLogsDir() async {
    // まず exe と同じフォルダ配下 logs/ を優先
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final d = Directory(p.join(exeDir.path, "logs"));
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    } catch (_) {
      // 置き場所が Program Files 等で書けない場合の保険
      final appSupport = await getApplicationSupportDirectory();
      final d = Directory(p.join(appSupport.path, "logs"));
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pack = _pack;
    final turn = _turn;

    final emotion = turn?.emotion ?? pack?.defaultEmotion ?? Emotion.idle;
    final sprite = pack?.sprites[emotion];
    final imgPath = (_mouthOpen ? sprite?.openPath : sprite?.closedPath);

    final choiceProfile = turn?.choiceProfile ?? pack?.defaultChoiceProfile ?? ChoiceProfile.idleDefault;
    final choices = turn?.choices.isNotEmpty == true ? turn!.choices : _choicesForProfile(choiceProfile);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Avatar
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _onAvatarTap,
              onSecondaryTapDown: (d) => _showContextMenu(d.globalPosition),
              onPanStart: (d) => _maybeStartDrag(d.localPosition),
              child: imgPath == null
                  ? const Center(child: Text("Loading...", style: TextStyle(color: Colors.white)))
                  : Image.file(File(imgPath), fit: BoxFit.contain),
            ),
          ),

          // Speech bubble
          if (_bubbleVisible && (turn != null || _isGeminiBusy))
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
                child: _SpeechBubble(
                  title: pack?.name ?? "Mascot",
                  text: turn?.text ?? "",
                  choices: _isGeminiBusy ? const [] : (turn?.choices ?? const []),
                  onChoice: _onChoice,
                  isThinking: _isGeminiBusy, // 追加
                  contextTitle: _bubbleContextTitle, // ←RSSの時だけ入れる
                ),
              ),
            ),
        ],
      ),
    );
  }

  // === Gemini settings ===

  Map<String, dynamic> _mascotTurnSchema({required List<String> emotionEnum}) {
    // response_schema は curl例のように大文字Typeを使う形式で合わせます。:contentReference[oaicite:3]{index=3}
    return {
      "type": "OBJECT",
      "properties": {
        "v": {"type": "INTEGER"},
        "text": {"type": "STRING"},
        "emotion": {"type": "STRING", "enum": emotionEnum},
        "choice_profile": {
          "type": "STRING",
          "enum": ["none", "idle_default", "rss_default", "input_offer"]
        },
        "choices": {
          "type": "ARRAY",
          "minItems": 0,
          "maxItems": 3,
          "items": {
            "type": "OBJECT",
            "properties": {
              "id": {"type": "STRING", "enum": ["c1", "c2", "c3"]},
              "label": {"type": "STRING"},
              "intent": {
                "type": "STRING",
                "enum": [
                  "core.more",
                  "core.change_topic",
                  "core.quiet_mode",
                  "core.ok",
                  "core.nope",
                  "core.open_input",
                  "core.open_link"
                ]
              }
            },
            "required": ["id", "label", "intent"]
          }
        },
        "debug_line_id": {"type": "STRING"}
      },
      "required": ["v", "text", "emotion", "choice_profile", "choices"]
    };
  }

  Future<MascotTurn> _callGeminiTurn({
    required String apiKey,
    required String model, // "gemini-3-flash-preview"
    required String systemPrompt,
    required String userPrompt,
    required List<String> emotionEnum,
  }) async {
    final uri = Uri.parse(
      "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey",
    );

    final body = {
      // system_instruction のcurl例に合わせて snake_case を使います。:contentReference[oaicite:4]{index=4}
      "system_instruction": {
        "parts": [
          {"text": systemPrompt}
        ]
      },
      "contents": [
        {
          "role": "user",
          "parts": [
            {"text": userPrompt}
          ]
        }
      ],
      "generationConfig": {
        "response_mime_type": "application/json",
        "responseJsonSchema": _mascotTurnSchema(emotionEnum: emotionEnum),
        "temperature": 1.0,
        "thinkingConfig": {
          "thinkingLevel": "low"
        },
        "maxOutputTokens": 2048
      }
    };

    final resp = await http.post(
      uri,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(body),
    );

    if (resp.statusCode != 200) {
      throw Exception("Gemini HTTP ${resp.statusCode}: ${resp.body}");
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception("Gemini: response is not a JSON object");
    }

    final candidatesAny = decoded["candidates"];
    if (candidatesAny is! List || candidatesAny.isEmpty) {
      final pf = decoded["promptFeedback"];
      throw Exception("Gemini: no candidates. promptFeedback=${jsonEncode(pf)}");
    }

    final cand0Any = candidatesAny.first;
    if (cand0Any is! Map<String, dynamic>) {
      throw Exception("Gemini: bad candidate shape");
    }
    final finishReason = cand0Any["finishReason"]?.toString();

    final contentAny = cand0Any["content"];
    if (contentAny is! Map<String, dynamic>) {
      throw Exception("Gemini: no content. finishReason=$finishReason");
    }

    final partsAny = contentAny["parts"];
    if (partsAny is! List || partsAny.isEmpty) {
      throw Exception("Gemini: no parts. finishReason=$finishReason");
    }

    // parts が複数ある可能性もあるので text を連結
    final text = partsAny
        .whereType<Map>()
        .map((p) => p["text"])
        .whereType<String>()
        .join("");

    if (text.trim().isEmpty) {
      throw Exception("Gemini: empty text. finishReason=$finishReason");
    }

    // response_mime_type=application/json なので text は JSON 文字列想定
    final obj = jsonDecode(text);
    if (obj is! Map<String, dynamic>) {
      throw Exception("Gemini: model output is not a JSON object");
    }

    final turn = MascotTurn(
      v: (obj["v"] as num).toInt(),
      text: obj["text"] as String,
      emotion: MascotTurn.parseEmotion(obj["emotion"] as String),
      choiceProfile: MascotTurn.parseChoiceProfile(obj["choice_profile"] as String),
      choices: ((obj["choices"] as List?) ?? [])
          .cast<Map<String, dynamic>>()
          .map((m) => MascotChoice(
                id: m["id"] as String,
                label: m["label"] as String,
                intent: MascotTurn.parseIntent(m["intent"] as String),
              ))
          .toList(),
      debugLineId: (obj["debug_line_id"] as String?)?.trim().isEmpty == true ? null : (obj["debug_line_id"] as String?),
    );

    return turn;
  }

  Future<MascotTurn?> _requestGeminiTurn({
    required String where,        // "gemini_idle" / "gemini_rss" / "gemini_followup" など
    required String mode,         // idle|rss|followup
    required String from,         // ログ用（不要なら "" でもOK）
    required String userPrompt,
  }) async {
    final pack = _pack;
    if (pack == null) return null;

    final cfg = _config;
    if (cfg == null || cfg.geminiApiKey.trim().isEmpty) {
      setState(() => _turn = MascotTurn.fallback(
          "APIキー未設定。\n$_configFileName を exe と同じフォルダに置いて、gemini_api_key を書いて再起動して。\n($_configPath)"));
      await _logEvent("error", {
        "where": where,
        "error": "missing_config_or_key",
        "config_path": _configPath,
      });
      return null;
    }

    // 多重呼び出し防止（クリック連打・別モード同時実行）

    if (_isGeminiBusy) return null;


    _setGeminiBusy(true);
    _showBubble(); // busy中の …… を見せる前提
    try {
      final t = await _callGeminiTurn(
        apiKey: cfg.geminiApiKey,
        model: "gemini-3-flash-preview",
        systemPrompt: pack.systemPrompt,
        userPrompt: userPrompt,
        emotionEnum: pack.emotionIds,
      );
      return t;
    } catch (e, st) {
      await _logEvent("error", {
        "where": where,
        "error": _trimForLog(e.toString()),
        "stack": _trimForLog(st.toString()),
      });
      setState(() => _turn = MascotTurn.fallback("…通信が荒れている。${e.toString()}"));
      return null;
    } finally {
      _setGeminiBusy(false);
    }
  }

  String _buildUserPrompt({
    required String mode, // idle|followup|rss(今回は手動でもOK)
    required int maxChars,
    String? lastIntentWire,
    String? lastMascotText,
    Map<String, String>? topic, // title/snippet/url
  }) {
    // 「スクリプトに結合しない」ために、User promptはただのテキストです。
    final b = StringBuffer();
    b.writeln("MODE: $mode");
    b.writeln("MAX_CHARS: $maxChars");
    final choiceProfileHint = switch (mode) {
      "idle" => "idle_default",
      "rss" => "rss_default",
      _ => "none",
    };
    b.writeln("CHOICE_PROFILE_HINT: $choiceProfileHint");
    if (lastIntentWire != null) b.writeln("LAST_INTENT: $lastIntentWire");
    if (lastMascotText != null) b.writeln("LAST_MASCOT_TEXT: $lastMascotText");
    if (topic != null) {
      b.writeln("TOPIC_TITLE: ${topic["title"] ?? ""}");
      b.writeln("TOPIC_SNIPPET: ${topic["snippet"] ?? ""}");
      b.writeln("TOPIC_URL: ${topic["url"] ?? ""}");
    }
    // 直近の重複除外ヒント
    final hints = _dedupe.buildHints(maxHints: _config?.dedupePromptHints ?? 10);
    if (hints.isNotEmpty) {
      b.writeln("AVOID_SAME_TOPICS:");
      for (final h in hints) {
        b.writeln("- $h");
      }
      b.writeln("Rule: 上の話題と同じ内容・同じ結論・同じ例えを避け、別の観察や別角度の雑談にする。");
    }
    
    b.writeln("");
    b.writeln("次の1ターンをJSONで返して。textは短く、URLは入れない。");
    return b.toString();
  }

  Future<File> _getStateFile() async {
    final exeDir = File(Platform.resolvedExecutable).parent;
    return File(p.join(exeDir.path, _stateFileName));
  }

  Future<void> _loadDedupeState() async {
    final f = await _getStateFile();
    _statePath = f.path;
    final cfg = _config;
    final maxEntries = cfg?.dedupeRecentTurns ?? 120;
    _dedupe = await _DedupeState.load(f, maxEntries: maxEntries);
  }

  // ===== rss functions =====
  Future<File> _exeSiblingFile(String name) async {
    final exeDir = File(Platform.resolvedExecutable).parent;
    return File(p.join(exeDir.path, name));
  }

  Future<RssSettings?> _loadRssSettings() async {
    final f = await _exeSiblingFile(_rssSettingsFileName);

    if (!f.existsSync()) {
      final tpl = RssSettings.template();
      await f.writeAsString(const JsonEncoder.withIndent("  ").convert(tpl.toJson()));
      await _logEvent("rss", {"status": "created_settings_template", "path": f.path});
      return null;
    }

    try {
      final obj = jsonDecode(await f.readAsString());
      return RssSettings.fromJson(obj);
    } catch (e, st) {
      await _logEvent("error", {"where": "rss_load_settings", "error": e.toString(), "stack": st.toString()});
      return null;
    }
  }

  Future<void> _loadRssCache() async {
    final f = await _exeSiblingFile(_rssCacheFileName);
    if (!f.existsSync()) {
      _rssCache = RssCache([]);
      return;
    }
    try {
      _rssCache = RssCache.fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {
      _rssCache = RssCache([]);
    }
  }

  Future<void> _loadRssState() async {
    final f = await _exeSiblingFile(_rssStateFileName);
    if (!f.existsSync()) {
      _rssState = RssState.empty();
      return;
    }
    try {
      _rssState = RssState.fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {
      _rssState = RssState.empty();
    }
  }

  Future<void> _saveRssState() async {
    final f = await _exeSiblingFile(_rssStateFileName);
    await f.writeAsString(const JsonEncoder.withIndent("  ").convert(_rssState.toJson()));
  }

  String _feedKeyFromUrl(String url) {
    final h = sha256.convert(utf8.encode(url)).toString();
    return "u:$h";
  }

  Future<void> _saveRssCache() async {
    final f = await _exeSiblingFile(_rssCacheFileName);
    await f.writeAsString(const JsonEncoder.withIndent("  ").convert(_rssCache.toJson()));
  }

  bool _rssHasItemId(String itemId) => _rssCache.items.any((e) => e.itemId == itemId);

  List<RssItem> _parseFeedXml({required String feedId, required String sourceHost, required String xmlText}) {
    // NOTE: We keep the name for minimal diff, but this is no longer "xml.dart".
    // webfeed supports RSS (0.9/1.0/2.0) and Atom.
    String _bestAtomLink(List<wf.AtomLink>? links) {
      if (links == null || links.isEmpty) return '';
      // Prefer rel="alternate" (or empty rel), otherwise fall back to first href.
      for (final l in links) {
        final href = (l.href ?? '').trim();
        if (href.isEmpty) continue;
        final rel = (l.rel ?? '').trim();
        if (rel.isEmpty || rel == 'alternate') return href;
      }
      for (final l in links) {
        final href = (l.href ?? '').trim();
        if (href.isNotEmpty) return href;
      }
      return '';
    }

    // Try RSS first.
    try {
      final feed = wf.RssFeed.parse(xmlText);
      final items = feed.items ?? const <wf.RssItem>[];
      final out = <RssItem>[];
      for (final it in items) {
        final title = _stripTags(it.title ?? '').trim();
        final link = (it.link ?? '').trim();
        final guid = (it.guid ?? '').trim();

        final dc = it.dc;
        final publishedAt =
            (it.pubDate ?? dc?.date ?? dc?.created ?? dc?.modified)?.toLocal()
            // どうしても日付が取れないフィード用の保険（取れないせいでcapで全落ちするのを防ぐ）
            ?? DateTime.now();

        // Prefer description, then content:encoded.
        final summaryRaw = (it.description ?? it.content?.value ?? '');
        final summary = _stripTags(summaryRaw).trim();

        final stableKey = (guid.isNotEmpty ? guid : (link.isNotEmpty ? link : title)).trim();
        if (stableKey.isEmpty) continue;

        final itemId = '$feedId:${sha256.convert(utf8.encode(stableKey)).toString()}';

        out.add(RssItem(
          feedId: feedId,
          sourceHost: sourceHost,
          itemId: itemId,
          title: title.isEmpty ? '(no title)' : title,
          link: link,
          publishedAt: publishedAt,
          summary: summary,
        ));
      }
      return out;
    } catch (_) {
      // fallthrough
    }

    // Atom.
    final atom = wf.AtomFeed.parse(xmlText);
    final items = atom.items ?? const <wf.AtomItem>[];
    final out = <RssItem>[];
    for (final it in items) {
      final title = _stripTags(it.title ?? '').trim();
      final link = _bestAtomLink(it.links);
      final id = (it.id ?? '').trim();

      final publishedAt = (it.updated?.toLocal()) ?? _parseRssDate(it.published);

      final summaryRaw = (it.summary ?? it.content ?? '');
      final summary = _stripTags(summaryRaw).trim();

      final stableKey = (id.isNotEmpty ? id : (link.isNotEmpty ? link : title)).trim();
      if (stableKey.isEmpty) continue;

      final itemId = '$feedId:${sha256.convert(utf8.encode(stableKey)).toString()}';

      out.add(RssItem(
        feedId: feedId,
        sourceHost: sourceHost,
        itemId: itemId,
        title: title.isEmpty ? '(no title)' : title,
        link: link,
        publishedAt: publishedAt,
        summary: summary,
      ));
    }
    return out;
  }

  Future<void> _fetchRssOnce() async {
    try {

    final s = _rssSettings;
    if (s == null) {
      setState(() => _turn = MascotTurn.fallback("rss_feeds.json が未設定。exe隣に作ったテンプレを編集して。"));
      return;
    }

    final feeds = s.feeds.where((f) => f.enabled && f.id.isNotEmpty && f.url.isNotEmpty).toList();
    if (feeds.isEmpty) {
      setState(() => _turn = MascotTurn.fallback("RSS: 有効なfeedが無い。rss_feeds.json を確認して。"));
      return;
    }

    await _logEvent("rss", {
      "status": "fetch_start",
      "feeds": feeds.map((e) => {"id": e.id, "url": e.url}).toList(),
      "max_cache_items": s.maxCacheItems,
    });

    String _decodeBodyBytes(List<int> bytes) {
      // Most feeds are UTF-8. If it isn't, we still try to keep XML structure parseable.
      try {
        return utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        return latin1.decode(bytes);
      }
    }

    int added = 0;
    final cap = s.maxCacheItems.clamp(10, 9999);
    final perFeedTake = max(8, min(40, (cap / max(1, feeds.length)).ceil() + 4));

    for (final f in feeds) {
      try {
        final resp = await http
            .get(
              Uri.parse(f.url),
              headers: {
                "User-Agent": "nondesu/0.1 (+https://github.com/godmt/nondesu)",
                "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.8",
              },
            )
            .timeout(const Duration(seconds: 12));

        if (resp.statusCode != 200) {
          await _logEvent("rss_error", {
            "feed": f.id,
            "url": f.url,
            "code": resp.statusCode,
            "content_type": resp.headers["content-type"],
            "body": _trimForLog(resp.body),
          });
          continue;
        }

        final xmlText = _decodeBodyBytes(resp.bodyBytes);
        List<RssItem> items;
        try {
          final uri = Uri.parse(f.url);
          final sourceHost = uri.host.toLowerCase();
          items = _parseFeedXml(feedId: f.id, sourceHost: sourceHost, xmlText: xmlText);
        } catch (e, st) {
          await _logEvent("rss_error", {
            "feed": f.id,
            "url": f.url,
            "error": "parse_failed: ${e.toString()}",
            "stack": _trimForLog(st.toString()),
            "content_type": resp.headers["content-type"],
            "body_head": _trimForLog(xmlText),
          });
          continue;
        }

        // 最新をつまみ食い（古いログで2022年が埋まる問題を避ける）
        items.sort((a, b) {
          final ta = a.publishedAt?.millisecondsSinceEpoch ?? 0;
          final tb = b.publishedAt?.millisecondsSinceEpoch ?? 0;
          return tb.compareTo(ta); // desc
        });
        
        final now = DateTime.now();
        final defaultLookback = s.lookbackDays;
        final feedLookback = (f.lookbackDays ?? defaultLookback).clamp(1, 3650);

        DateTime since = now.subtract(Duration(days: feedLookback));

        // 前回の lastSeen から「差分」も見る（取りこぼし防止に少しだけ重ねる）
        final feedKey = _feedKeyFromUrl(f.url);
        final lastSeenIso = _rssState.lastSeenByFeed[feedKey];
        final lastSeen = (lastSeenIso == null) ? null : DateTime.tryParse(lastSeenIso);
        if (lastSeen != null) {
          final overlap = lastSeen.subtract(const Duration(hours: 6));
          if (overlap.isAfter(since)) since = overlap;
        }

        int feedAdded = 0;
        int taken = 0;

        // feedの「最新」を state に進める（新規が無くても進める）
        DateTime? newestSeenUtc;

        for (final it in items) {
          if (taken >= perFeedTake) break;

          final pub = it.publishedAt;
          if (pub != null) {
            // items は desc ソート済みなので、古くなったら終了
            if (pub.isBefore(since)) break;

            final u = pub.toUtc();
            if (newestSeenUtc == null || u.isAfter(newestSeenUtc)) newestSeenUtc = u;
          }

          if (it.title.trim().isEmpty && it.summary.trim().isEmpty) continue;
          if (_rssHasItemId(it.itemId)) continue;

          // 既読は「採用しない」
          if (_rssState.isRead(it.itemId)) continue;

          _rssCache.items.add(it);
          added++;
          feedAdded++;
          taken++;
        }

        // lastSeen 更新
        if (newestSeenUtc != null) {
          _rssState.lastSeenByFeed[feedKey] = newestSeenUtc.toIso8601String();
        }

        await _logEvent("rss", {
          "status": "feed_done",
          "feed": f.id,
          "url": f.url,
          "parsed": items.length,
          "take": taken,
          "added": feedAdded,
        });
      } catch (e, st) {
        await _logEvent("rss_error", {
          "feed": f.id,
          "url": f.url,
          "error": e.toString(),
          "stack": _trimForLog(st.toString()),
        });
      }
    }

    // キャッシュは「最新優先」で cap に収める（古いのが残り続けるのを防ぐ）
    _rssCache.items.sort((a, b) {
      final ta = a.publishedAt?.millisecondsSinceEpoch ?? 0;
      final tb = b.publishedAt?.millisecondsSinceEpoch ?? 0;
      return tb.compareTo(ta); // desc
    });
    if (_rssCache.items.length > cap) {
      _rssCache.items = _rssCache.items.sublist(0, cap);
    }

    await _saveRssCache();
    _rssState.lastFetchAtUtc = DateTime.now().toUtc();
    await _saveRssState();
    await _logEvent("rss", {"status": "fetch_done", "added": added, "cache_size": _rssCache.items.length});

    setState(() => _turn = MascotTurn.fallback("RSS更新: +$added 件（キャッシュ ${_rssCache.items.length}）"));
  
    } finally {
      // 何経由でも「喋った後」はクールダウンをリセット
      _scheduleNextIdle();
    }
}

  String _htmlUnescapeLite(String s) {
    return s
        .replaceAll("&amp;", "&")
        .replaceAll("&quot;", "\"")
        .replaceAll("&#39;", "'")
        .replaceAll("&lt;", "<")
        .replaceAll("&gt;", ">");
  }

  String? _extractMetaDescription(String html) {
    final og = RegExp(
      r'''<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']+)["']''',
      caseSensitive: false,
    );
    final m1 = og.firstMatch(html);
    if (m1 != null) return _htmlUnescapeLite(m1.group(1) ?? "").trim();

    final og2 = RegExp(
      r'''<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:description["']''',
      caseSensitive: false,
    );
    final m3 = og2.firstMatch(html);
    if (m3 != null) return _htmlUnescapeLite(m3.group(1) ?? "").trim();

    final name = RegExp(
      r'''<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["']''',
      caseSensitive: false,
    );
    final m2 = name.firstMatch(html);
    if (m2 != null) return _htmlUnescapeLite(m2.group(1) ?? "").trim();

    return null;
  }

  Future<String?> _fetchLinkPreviewSummary(String url, {required int maxChars}) async {
    try {
      final resp = await http
          .get(
            Uri.parse(url),
            headers: {
              "User-Agent": "nondesu/0.1 (+https://github.com/godmt/nondesu)",
              "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
            },
          )
          .timeout(const Duration(seconds: 12));

      if (resp.statusCode != 200) return null;

      final html = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final desc = _extractMetaDescription(html);
      if (desc == null || desc.trim().isEmpty) return null;

      final t = desc.trim();
      return (t.length <= maxChars) ? t : "${t.substring(0, maxChars)}…";
    } catch (_) {
      return null;
    }
  }

  // 「未読を選んで喋る」+ 既読マーキング
  RssItem? _pickUnreadRssItem() {
    if (_rssCache.items.isEmpty) return null;

    final items = List<RssItem>.from(_rssCache.items);
    items.sort((a, b) {
      final ta = a.publishedAt?.millisecondsSinceEpoch ?? 0;
      final tb = b.publishedAt?.millisecondsSinceEpoch ?? 0;
      return tb.compareTo(ta);
    });

    for (final it in items) {
      if (_rssState.isRead(it.itemId)) continue;
      if (it.title.trim().isEmpty && it.summary.trim().isEmpty) continue;
      return it;
    }
    return null;
  }

  // RSS用Gemini呼び出しを追加（summary補完 + 既読化）
  Future<void> _doGeminiRssTalk({String from = "rss_menu"}) async {
    // Gemini 通信中は開始しない（多重呼び出し防止）
    if (_isGeminiBusy) return;

    try {

    final pack = _pack;
    final cfg = _config;
    if (pack == null || cfg == null) return;

    final s = _rssSettings;
    if (s == null) {
      setState(() => _turn = MascotTurn.fallback("rss_feeds.json が未設定。"));
      return;
    }

    final it = _pickUnreadRssItem();
    if (it == null) {
      setState(() => _turn = MascotTurn.fallback("RSS: 未読が無い。"));
      return;
    }
    _bubbleContextTitle = it.title;

    // summaryが無いタイプは採用時だけ link preview（あなたの現行のまま）
    if (it.summary.trim().isEmpty &&
        s.linkPreviewEnabled &&
        it.link.trim().isNotEmpty &&
        _domainAllowedForPreview(
          linkUrl: it.link,
          sourceHost: it.sourceHost,
          allowDomains: s.linkPreviewAllowDomains,
        )) {
      final sum = await _fetchLinkPreviewSummary(it.link, maxChars: s.linkPreviewMaxChars);
      if (sum != null && sum.trim().isNotEmpty) {
        it.summary = sum.trim();
        await _saveRssCache();
      }
    }

    final topic = {
      "title": it.title,
      "snippet": it.summary,
      "url": it.link,
    };
    _lastOpenLinkUrl = it.link.trim().isEmpty ? null : it.link.trim();

    final userPrompt = _buildUserPrompt(mode: "rss", maxChars: 90, topic: topic);

    final t = await _requestGeminiTurn(
      where: "gemini_rss",
      mode: "rss",
      from: from,
      userPrompt: userPrompt,
    );
    if (t == null) return;

    // 既読化（採用したので）
    _rssState.markRead(it.itemId, keepMax: s.readKeepMax);
    await _saveRssState();

    setState(() => _turn = t);
    _startMouthFlap();
    await _recordForDedupe(t);

    await _logEvent("rss", {
      "status": "picked_unread",
      "from": from,
      "picked_item_id": it.itemId,
      "picked_title": it.title,
      "picked_url": it.link,
    });
    await _logEvent("turn", {"mode": "rss", "from": from, "turn": t.toLogJson()});
  
    } finally {
      // 何経由でも「喋った後」はクールダウンをリセット
      _scheduleNextIdle();
    }
}

  bool _isPrivateOrLocalHost(String host) {
    final h = host.toLowerCase();
    if (h == "localhost" || h.endsWith(".local")) return true;
    final ip = InternetAddress.tryParse(h);
    if (ip == null) return false;
    if (ip.type != InternetAddressType.IPv4) return false;
    final b = ip.rawAddress;
    // 10.0.0.0/8
    if (b[0] == 10) return true;
    // 172.16.0.0/12
    if (b[0] == 172 && (b[1] >= 16 && b[1] <= 31)) return true;
    // 192.168.0.0/16
    if (b[0] == 192 && b[1] == 168) return true;
    // 127.0.0.0/8
    if (b[0] == 127) return true;
    // 0.0.0.0
    if (b[0] == 0) return true;
    return false;
  }

  // 超ざっくり base-domain（eTLD+1 の正確版は Public Suffix List が必要）
  // ここでは「末尾2ラベル」を採用。co.uk系は例外があるが、困ったら allow_domains で救済。
  String _roughBaseDomain(String host) {
    final parts = host.split('.').where((p) => p.isNotEmpty).toList();
    if (parts.length <= 2) return host;
    return "${parts[parts.length - 2]}.${parts[parts.length - 1]}";
  }

  bool _domainAllowedForPreview({
    required String linkUrl,
    required String sourceHost,
    required List<String> allowDomains, // user optional
  }) {
    Uri u;
    try { u = Uri.parse(linkUrl); } catch (_) { return false; }
    final scheme = u.scheme.toLowerCase();
    if (scheme != "http" && scheme != "https") return false;

    final host = u.host.toLowerCase();
    if (host.isEmpty) return false;
    if (_isPrivateOrLocalHost(host)) return false;

    // 1) same-domain（デフォルト）
    if (sourceHost.isNotEmpty) {
      final a = _roughBaseDomain(host);
      final b = _roughBaseDomain(sourceHost.toLowerCase());
      if (a == b) return true;
      // ついでに「同一host/サブドメイン」も許可
      if (host == sourceHost.toLowerCase() || host.endsWith(".${sourceHost.toLowerCase()}")) return true;
    }

    // 2) allow_domains が指定されていれば追加許可（上級者用）
    for (final d in allowDomains) {
      final dd = d.toLowerCase().trim();
      if (dd.isEmpty) continue;
      if (host == dd || host.endsWith(".$dd")) return true;
    }
    return false;
  }

  Future<bool> _openExternalUrl(String url) async {
    // 安全のため http/https のみ許可（file:// 等は弾く）
    Uri u;
    try {
      u = Uri.parse(url);
    } catch (_) {
      return false;
    }
    final scheme = u.scheme.toLowerCase();
    if (scheme != "http" && scheme != "https") return false;

    try {
      // Windows: rundll32（なぜこの名: DLL関数を呼び出す実行ファイル）で既定ブラウザを開く
      if (Platform.isWindows) {
        await Process.start(
          "rundll32",
          ["url.dll,FileProtocolHandler", url],
          runInShell: true,
        );
        return true;
      }

      // 将来のMac/Linux対応も一応（今はWindowsのみでもOK）
      if (Platform.isMacOS) {
        await Process.start("open", [url], runInShell: true);
        return true;
      }
      if (Platform.isLinux) {
        await Process.start("xdg-open", [url], runInShell: true);
        return true;
      }

      return false;
    } catch (e, st) {
      await _logEvent("error", {
        "where": "open_link",
        "url": url,
        "error": e.toString(),
        "stack": st.toString(),
      });
      return false;
    }
  }
}
