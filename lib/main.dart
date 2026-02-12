import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:http/http.dart' as http;
import 'package:webfeed/webfeed.dart' as wf;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // acrylic init first
  await Window.initialize();

  // Window init
  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(360, 520),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    alwaysOnTop: true,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    // フレーム/影を消す
    await windowManager.setAsFrameless();      // outline border等を除去
    await windowManager.setHasShadow(false);   // Windowsではframeless時にだけ効く

    await Window.setWindowBackgroundColorToClear();
    await Window.makeTitlebarTransparent();
    await Window.addEmptyMaskImage();
    await Window.disableShadow();

    // 影は念のためこちらも（flutter_acrylic側）
    try { Window.disableShadow(); } catch (_) {}

    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const MascotApp());
}

class MascotApp extends StatelessWidget {
  const MascotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LLM Mascot',
      debugShowCheckedModeBanner: false,
      home: const MascotHome(),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
    );
  }
}

class AppConfig {
  final String geminiApiKey;
  final int idleTalkMinSec;
  final int idleTalkMaxSec;

  final int dedupeRecentTurns;
  final int dedupeHammingThreshold;
  final int dedupePromptHints;

  AppConfig({
    required this.geminiApiKey,
    required this.idleTalkMinSec,
    required this.idleTalkMaxSec,
    required this.dedupeRecentTurns,
    required this.dedupeHammingThreshold,
    required this.dedupePromptHints,
  });
}

typedef EmotionId = String;

const String kEmotionIdle = "idle";
const String kEmotionHappy = "happy";
const String kEmotionAnnoyed = "annoyed";
const String kEmotionThink = "think";

const String kSystemPromptTemplateV1 = '''
あなたはデスクトップマスコットの「次の1ターン」を生成します。
必ず “JSONオブジェクト1つだけ” を返してください。前置き・解説・Markdown禁止。
全ての発言（text）において、CHARACTER_PROMPTで示されるキャラクターをロールプレイしてください。

## 出力フォーマット（MascotTurn v1）
{
  "v": 1,
  "text": string,
  "emotion": string,
  "choice_profile": "none"|"idle_default"|"rss_default"|"input_offer",
  "choices": [
    {"id":"c1"|"c2"|"c3","label":string,"intent":"core.more"|"core.change_topic"|"core.quiet_mode"|"core.ok"|"core.nope"|"core.open_input"|"core.open_link"}
  ],
  "debug_line_id": string | null
}

## 共通ルール
- textは短く。指定がなければ idle:70文字以内 / rss:90文字以内。
- URLをtextに含めない（ボタン core.open_link で開く想定）。
- 断定しすぎない。topicは「タイトルと要旨を渡された」以上の確度で語らない。
- 質問で終えるのは控えめ（指定がなければ10%以下）。
- choicesは0〜3個。labelはユーザーが押すUI文言なのでロールプレイ不要。短い日本語で自然に。
- TOPICにurlがある場合: choices内に intent=core.open_link を必ず1つ含める
  （choicesを空にするなら choice_profile=rss_default にすること）。
- choice_profile は “ボタンセットの型” のガイド。choicesを出した場合は choices が優先。
- 「ユーザーは基本話しかけない」前提で、眺めるだけで成立する一言にする。

## CHARACTER_PROMPT
{{CHARACTER_PROMPT}}

## 入力（userPrompt）
- MODE: idle / rss / followup
- MAX_CHARS: 数字（任意）
- CHOICE_PROFILE_HINT: none / idle_default / rss_default / input_offer（任意）
- rss の場合は TOPIC が入る（title/snippet/url/tags）
- followup の場合は LAST_INTENT が入る

それでは、次の1ターンを生成してJSONだけ返せ。
''';

String _buildSystemPromptV1(String characterPrompt) =>
    kSystemPromptTemplateV1.replaceAll("{{CHARACTER_PROMPT}}", characterPrompt.trim());

enum Emotion { idle, happy, annoyed, think }

enum ChoiceProfile { none, idleDefault, rssDefault, inputOffer }

enum Intent {
  more,
  changeTopic,
  quietMode,
  ok,
  nope,
  openInput,
  openLink,
}

class MascotChoice {
  final String id; // c1/c2/c3
  final String label;
  final Intent intent;

  MascotChoice({required this.id, required this.label, required this.intent});
}

class MascotTurn {
  final int v; // always 1
  final String text;
  final EmotionId emotion;
  final ChoiceProfile choiceProfile;
  final List<MascotChoice> choices;
  final String? debugLineId;

  MascotTurn({
    required this.v,
    required this.text,
    required this.emotion,
    required this.choiceProfile,
    required this.choices,
    required this.debugLineId,
  });

  MascotTurn.fallback(String text)
      : v = 1,
        text = text,
        emotion = kEmotionIdle,
        choiceProfile = ChoiceProfile.idleDefault,
        choices = const [],
        debugLineId = "fallback.local";

  Map<String, dynamic> toLogJson() => {
        "v": v,
        "text": text.length > 240 ? "${text.substring(0, 240)}…" : text,
        "emotion": emotion,
        "choice_profile": _choiceProfileToWire(choiceProfile),
        "choices": choices
            .map((c) => {"id": c.id, "label": c.label, "intent": _intentToWire(c.intent)})
            .toList(),
        "debug_line_id": debugLineId,
      };

  static EmotionId parseEmotion(String s) {
    final t = s.trim().toLowerCase();
    return t.isEmpty ? kEmotionIdle : t;
  }

  static ChoiceProfile parseChoiceProfile(String s) {
    switch (s) {
      case "none":
        return ChoiceProfile.none;
      case "rss_default":
        return ChoiceProfile.rssDefault;
      case "input_offer":
        return ChoiceProfile.inputOffer;
      case "idle_default":
      default:
        return ChoiceProfile.idleDefault;
    }
  }

  static Intent parseIntent(String s) {
    switch (s) {
      case "core.more":
        return Intent.more;
      case "core.change_topic":
        return Intent.changeTopic;
      case "core.quiet_mode":
        return Intent.quietMode;
      case "core.ok":
        return Intent.ok;
      case "core.nope":
        return Intent.nope;
      case "core.open_input":
        return Intent.openInput;
      case "core.open_link":
        return Intent.openLink;
      default:
        return Intent.more;
    }
  }
}

String _choiceProfileToWire(ChoiceProfile p) {
  switch (p) {
    case ChoiceProfile.none:
      return "none";
    case ChoiceProfile.rssDefault:
      return "rss_default";
    case ChoiceProfile.inputOffer:
      return "input_offer";
    case ChoiceProfile.idleDefault:
    default:
      return "idle_default";
  }
}

String _intentToWire(Intent i) {
  switch (i) {
    case Intent.more:
      return "core.more";
    case Intent.changeTopic:
      return "core.change_topic";
    case Intent.quietMode:
      return "core.quiet_mode";
    case Intent.ok:
      return "core.ok";
    case Intent.nope:
      return "core.nope";
    case Intent.openInput:
      return "core.open_input";
    case Intent.openLink:
      return "core.open_link";
  }
}

class MascotPack {
  final String id;
  final String name;
  final Size windowSize;
  final Map<EmotionId, SpritePair> sprites;
  final EmotionId defaultEmotion;
  final ChoiceProfile defaultChoiceProfile;
  final String systemPrompt;
  List<EmotionId> emotionIds;
  String characterPrompt;

  MascotPack({
    required this.id,
    required this.name,
    required this.windowSize,
    required this.sprites,
    required this.defaultEmotion,
    required this.defaultChoiceProfile,
    required this.systemPrompt,
    required this.emotionIds,
    required this.characterPrompt,
  });
}

class SpritePair {
  final String closedPath;
  final String openPath;

  SpritePair({required this.closedPath, required this.openPath});
}

// Mask for hit testing
class _RgbaMask {
  final int w;
  final int h;
  final Uint8List rgba; // rawRgba
  _RgbaMask(this.w, this.h, this.rgba);
}

Future<_RgbaMask?> _loadRgbaMask(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) return null;
    return _RgbaMask(img.width, img.height, bd.buffer.asUint8List());
  } catch (_) {
    return null;
  }
}

bool _isOpaqueAtContainFit({
  required Offset local,
  required Size widgetSize,
  required _RgbaMask mask,
  int alphaThreshold = 16,
}) {
  final scale = min(widgetSize.width / mask.w, widgetSize.height / mask.h);
  final dispW = mask.w * scale;
  final dispH = mask.h * scale;
  final offX = (widgetSize.width - dispW) / 2.0;
  final offY = (widgetSize.height - dispH) / 2.0;

  final x = local.dx - offX;
  final y = local.dy - offY;
  if (x < 0 || y < 0 || x >= dispW || y >= dispH) return false;

  final px = (x / scale).floor().clamp(0, mask.w - 1);
  final py = (y / scale).floor().clamp(0, mask.h - 1);

  final idx = (py * mask.w + px) * 4 + 3; // alpha
  final a = mask.rgba[idx];
  return a > alphaThreshold;
}

// ===== Home =====

class MascotHome extends StatefulWidget {
  const MascotHome({super.key});

  @override
  State<MascotHome> createState() => _MascotHomeState();
}

class _MascotHomeState extends State<MascotHome> with WindowListener {
  MascotPack? _pack;
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


  RssSettings? _rssSettings;
  RssCache _rssCache = RssCache([]);

  // Minimal "LLM not wired yet" talk pool
  final _localFallbackPool = const [
    "雨音って、都市のノイズをちょっとだけ丸くするよね。",
    "ネオンは正直だよ。光る気分の日だけ光る。",
    "…無理しない。今日はそれで十分。",
    "観察してるだけで、世界はわりと面白い。",
  ];

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
    final pack = await _loadFirstMascotPack();
    if (pack == null) {
      setState(() {
        _turn = MascotTurn.fallback("avatarsが見つからない。…配置、お願い。");
      });
      return;
    }
    _pack = pack;
    _config = await _loadConfig();
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
        const PopupMenuItem(value: "talk_rss", child: Text("RSS 未読を話す")),
        const PopupMenuItem(value: "update_rss", child: Text("RSS更新")),
        const PopupMenuItem(value: "exit", child: Text("終了")),
      ],
    );

    if (selected == "exit") {
      await windowManager.close();
    } else if (selected == "update_rss") {
      await _fetchRssOnce();
    } else if (selected == "talk_rss") {
      await _doGeminiRssTalk();
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

  Future<MascotPack?> _loadFirstMascotPack() async {
    final baseDir = await _resolveBaseDir();
    final avatarsDir = Directory(p.join(baseDir.path, "avatars"));
    if (!avatarsDir.existsSync()) return null;

    final children = avatarsDir
        .listSync()
        .whereType<Directory>()
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (children.isEmpty) return null;

    // pick first
    return _loadMascotPack(children.first);
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

  Future<AppConfig?> _loadConfig() async {
    final f = await _getConfigFile();
    _configPath = f.path;

    if (!f.existsSync()) {
      // 無ければテンプレを作って、ユーザーに編集してもらう
      final template = {
        "gemini_api_key": "PASTE_YOUR_KEY_HERE",
        "idle_talk_min_sec": 30,
        "idle_talk_max_sec": 90
      };
      await f.writeAsString(const JsonEncoder.withIndent("  ").convert(template));
      await _logEvent("config", {"status": "created_template", "path": f.path});
      return null;
    }

    try {
      final raw = await f.readAsString();
      final obj = jsonDecode(raw);
      if (obj is! Map<String, dynamic>) return null;

      final key = (obj["gemini_api_key"] ?? "").toString().trim();
      if (key.isEmpty || key == "PASTE_YOUR_KEY_HERE") return null;

      int readInt(String k, int def) {
        final v = obj[k];
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v.trim()) ?? def;
        return def;
      }

      // idle interval
      final minSec = readInt("idle_talk_min_sec", 30);
      final maxSec = readInt("idle_talk_max_sec", 90);

      // clamp & sanitize (シンプル安全柵)
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
    } catch (e, st) {
      await _logEvent("error", {
        "where": "load_config",
        "error": _trimForLog(e.toString()),
        "stack": _trimForLog(st.toString()),
        "path": f.path,
      });
      return null;
    }
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
    final pack = _pack;
    if (pack == null) return;

    final cfg = _config;
    if (cfg == null) {
      setState(() => _turn = MascotTurn.fallback(
          "APIキー未設定。\n$_configFileName を exe と同じフォルダに置いて、gemini_api_key を書いて再起動して。\n($_configPath)"));
      await _logEvent("error", {
        "where": "gemini_idle",
        "error": "missing_config_or_key",
        "config_path": _configPath,
      });
      return;
    }

    try {
      final userPrompt = _buildUserPrompt(mode: "idle", maxChars: 70);
      final t = await _callGeminiTurn(
        apiKey: cfg.geminiApiKey,
        model: "gemini-3-flash-preview",
        systemPrompt: pack.systemPrompt,
        userPrompt: userPrompt,
        emotionEnum: pack.emotionIds,
      );

      // 重複除外チェック
      final reason = _dedupeReason(t);
      if (reason != null) {
        await _logEvent("dedupe_reject", {
          "reason": reason,
          "state_path": _statePath,
          "text": _trimForLog(t.text),
          "debug_line_id": t.debugLineId,
        });

        // フォールバック台詞（短い固定セット）
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
    } catch (e, st) {
      await _logEvent("error", {
        "where": "gemini_idle",
        "error": _trimForLog(e.toString()),
        "stack": _trimForLog(st.toString()),
      });
      setState(() => _turn = MascotTurn.fallback("…エラー。${e.toString()}"));
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
    // PoC: click triggers immediate talk
    await _doGeminiIdleTalk(from: "avatar_tap");
  }

  Future<void> _onChoice(Intent intent) async {
    await _logEvent("choice", {"intent": _intentToWire(intent)});

    if (intent == Intent.quietMode) {
      _quietUntil = DateTime.now().add(const Duration(minutes: 30));
      _quiet = true;
      setState(() {
        _turn = MascotTurn.fallback("…了解。しばらく静かにしてる。");
      });
      _scheduleNextIdle();
      return;
    }

    // For now: local followups
    if (intent == Intent.changeTopic) {
      await _doGeminiIdleTalk(from: "user_change_topic");
      return;
    }
    if (intent == Intent.more) {
      setState(() {
        _turn = MascotTurn.fallback("うん。…今の話、もう一口だけ続けるとさ。");
      });
      _startMouthFlap();
      return;
    }
    if (intent == Intent.openInput) {
      final input = await _showInputDialog();
      if (input == null || input.trim().isEmpty) return;
      setState(() {
        _turn = MascotTurn.fallback("ふむ。…その話、ちゃんと聞く。");
      });
      _startMouthFlap();
      return;
    }
    if (intent == Intent.openLink) {
      setState(() {
        _turn = MascotTurn.fallback("元記事は…今は手動で開いてね（PoC）。");
      });
      _startMouthFlap();
      return;
    }
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
          if (turn != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
                child: _SpeechBubble(
                  title: pack?.name ?? "Mascot",
                  text: turn.text,
                  choices: choices,
                  onChoice: _onChoice,
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

    // summaryが無いタイプ（huggingface等）は、採用時だけ link preview
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
        await _saveRssCache(); // 補完したのでキャッシュ更新
      }
    }

    final topic = {
      "title": it.title,
      "snippet": it.summary,
      "url": it.link,
    };

    try {
      final userPrompt = _buildUserPrompt(mode: "rss", maxChars: 90, topic: topic);
      final t = await _callGeminiTurn(
        apiKey: cfg.geminiApiKey,
        model: "gemini-3-flash-preview",
        systemPrompt: pack.systemPrompt,
        userPrompt: userPrompt,
        emotionEnum: pack.emotionIds,
      );

      // 既読化（採用したので）
      _rssState.markRead(it.itemId, keepMax: s.readKeepMax);
      await _saveRssState();

      setState(() => _turn = t);
      await _logEvent("rss", {
        "status": "picked_unread",
        "from": from,
        "picked_item_id": it.itemId,
        "picked_title": it.title,
        "picked_url": it.link,
      });
    } catch (e, st) {
      await _logEvent("error", {
        "where": "gemini_rss",
        "error": e.toString(),
        "stack": st.toString(),
      });
      setState(() => _turn = MascotTurn.fallback("…通信が荒れている。${e.toString()}"));
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
}

class _SpeechBubble extends StatelessWidget {
  final String title;
  final String text;
  final List<MascotChoice> choices;
  final Future<void> Function(Intent) onChoice;

  const _SpeechBubble({
    required this.title,
    required this.text,
    required this.choices,
    required this.onChoice,
  });

  @override
  Widget build(BuildContext context) {
    final showChoices = choices.isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.18)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 14)),
            ),
            if (showChoices) ...[
              const SizedBox(height: 10),
              Row(
                children: choices.map((c) {
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () => onChoice(c.intent),
                        child: Text(c.label, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DedupeEntry {
  final String ts;
  final String textHash; // "sha256:..."
  final String simhashHex; // "0x...."
  final String? debugLineId;
  final String hint;

  _DedupeEntry({
    required this.ts,
    required this.textHash,
    required this.simhashHex,
    required this.debugLineId,
    required this.hint,
  });

  Map<String, dynamic> toJson() => {
    "ts": ts,
    "text_hash": textHash,
    "simhash": simhashHex,
    "debug_line_id": debugLineId,
    "hint": hint,
  };

  static _DedupeEntry? fromJson(dynamic j) {
    if (j is! Map) return null;
    return _DedupeEntry(
      ts: (j["ts"] ?? "").toString(),
      textHash: (j["text_hash"] ?? "").toString(),
      simhashHex: (j["simhash"] ?? "").toString(),
      debugLineId: (j["debug_line_id"] as String?),
      hint: (j["hint"] ?? "").toString(),
    );
  }
}

class _DedupeState {
  final List<_DedupeEntry> recent;
  _DedupeState(this.recent);

  static const int _v = 1;

  static Future<_DedupeState> load(File f, {required int maxEntries}) async {
    if (!f.existsSync()) return _DedupeState([]);
    try {
      final obj = jsonDecode(await f.readAsString());
      if (obj is! Map<String, dynamic>) return _DedupeState([]);
      final arr = obj["recent"];
      if (arr is! List) return _DedupeState([]);
      final entries = arr.map(_DedupeEntry.fromJson).whereType<_DedupeEntry>().toList();
      if (entries.length > maxEntries) {
        return _DedupeState(entries.sublist(entries.length - maxEntries));
      }
      return _DedupeState(entries);
    } catch (_) {
      return _DedupeState([]);
    }
  }

  Future<void> save(File f, {required int maxEntries}) async {
    final trimmed = recent.length > maxEntries
        ? recent.sublist(recent.length - maxEntries)
        : recent;
    final obj = {
      "v": _v,
      "recent": trimmed.map((e) => e.toJson()).toList(),
    };
    await f.writeAsString(const JsonEncoder.withIndent("  ").convert(obj));
  }

  List<String> buildHints({required int maxHints}) {
    final t = recent.length > maxHints ? recent.sublist(recent.length - maxHints) : recent;
    return t.map((e) => e.hint).toList();
  }
}

// ====== fingerprint helpers ======

final RegExp _reStrip = RegExp(r'[\s\p{P}\p{S}]', unicode: true);
String _norm(String s) => s.toLowerCase().replaceAll(_reStrip, '');

String _hintOf(String text, {int max = 32}) {
  final t = text.trim().replaceAll('\n', ' ');
  if (t.length <= max) return t;
  return "${t.substring(0, max)}…";
}

int _fnv1a64(String s) {
  const int offset = 0xcbf29ce484222325;
  const int prime = 0x100000001b3;
  const int mask = 0xFFFFFFFFFFFFFFFF;

  int h = offset;
  final bytes = utf8.encode(s);
  for (final b in bytes) {
    h ^= b;
    h = (h * prime) & mask;
  }
  return h & mask;
}

int _simhash64(String text) {
  const int mask = 0xFFFFFFFFFFFFFFFF;
  final n = _norm(text);
  if (n.length < 3) return _fnv1a64(n);

  final acc = List<int>.filled(64, 0);
  for (int i = 0; i <= n.length - 3; i++) {
    final tri = n.substring(i, i + 3);
    final h = _fnv1a64(tri);
    for (int b = 0; b < 64; b++) {
      acc[b] += ((h >> b) & 1) == 1 ? 1 : -1;
    }
  }

  int out = 0;
  for (int b = 0; b < 64; b++) {
    if (acc[b] > 0) out |= (1 << b);
  }
  return out & mask;
}

int _popcount64(int x) {
  int c = 0;
  while (x != 0) {
    x &= (x - 1);
    c++;
  }
  return c;
}

int _hamming64(int a, int b) => _popcount64((a ^ b) & 0xFFFFFFFFFFFFFFFF);

String _hex64(int x) => "0x${x.toRadixString(16).padLeft(16, '0')}";
int _parseHex64(String s) {
  final t = s.startsWith("0x") ? s.substring(2) : s;
  return int.tryParse(t, radix: 16) ?? 0;
}

// ====== RSS feed helper =====

class RssFeed {
  final String id;        // category id (ai/game/vtuber ...)
  final String url;       // feed url
  final bool enabled;
  final int? lookbackDays; // optional override per-feed

  RssFeed({
    required this.id,
    required this.url,
    required this.enabled,
    this.lookbackDays,
  });

  static RssFeed? fromJson(dynamic j) {
    if (j is! Map) return null;
    final lb = (j["lookback_days"] is num) ? (j["lookback_days"] as num).toInt() : null;
    return RssFeed(
      id: (j["id"] ?? "").toString().trim(),
      url: (j["url"] ?? "").toString().trim(),
      enabled: (j["enabled"] is bool) ? (j["enabled"] as bool) : true,
      lookbackDays: (lb == null) ? null : lb.clamp(1, 3650),
    );
  }

  Map<String, dynamic> toJson() => {
        "id": id,
        "url": url,
        "enabled": enabled,
        if (lookbackDays != null) "lookback_days": lookbackDays,
      };
}

class RssSettings {
  final List<RssFeed> feeds;
  final bool fetchOnStart;
  final int maxCacheItems;

  // NEW
  final int lookbackDays;          // default lookback
  final int readKeepMax;           // max stored read ids
  final bool linkPreviewEnabled;   // fetch link -> summary (on pick)
  final int linkPreviewMaxChars;
  final List<String> linkPreviewAllowDomains;

  RssSettings({
    required this.feeds,
    required this.fetchOnStart,
    required this.maxCacheItems,
    required this.lookbackDays,
    required this.readKeepMax,
    required this.linkPreviewEnabled,
    required this.linkPreviewMaxChars,
    required this.linkPreviewAllowDomains,
  });

  static RssSettings template() => RssSettings(
        feeds: [RssFeed(id: "ai", url: "https://example.com/feed.xml", enabled: true)],
        fetchOnStart: true,
        maxCacheItems: 80,
        lookbackDays: 7,
        readKeepMax: 2000,
        linkPreviewEnabled: true,
        linkPreviewMaxChars: 240,
        linkPreviewAllowDomains: const ["huggingface.co"],
      );

  Map<String, dynamic> toJson() => {
        "feeds": feeds.map((f) => f.toJson()).toList(),
        "fetch_on_start": fetchOnStart,
        "max_cache_items": maxCacheItems,
        "lookback_days": lookbackDays,
        "read_keep_max": readKeepMax,
        "link_preview": {
          "enabled": linkPreviewEnabled,
          "max_chars": linkPreviewMaxChars,
          "allow_domains": linkPreviewAllowDomains,
        },
      };

  static RssSettings? fromJson(dynamic j) {
    if (j is! Map) return null;

    final feedsAny = j["feeds"];
    final feeds = (feedsAny is List)
        ? feedsAny.map(RssFeed.fromJson).whereType<RssFeed>().toList()
        : <RssFeed>[];

    final fetch = (j["fetch_on_start"] is bool) ? (j["fetch_on_start"] as bool) : true;
    final maxItems = (j["max_cache_items"] is num) ? (j["max_cache_items"] as num).toInt() : 80;

    final lb = (j["lookback_days"] is num) ? (j["lookback_days"] as num).toInt() : 7;
    final keep = (j["read_keep_max"] is num) ? (j["read_keep_max"] as num).toInt() : 2000;

    final lp = (j["link_preview"] is Map) ? (j["link_preview"] as Map) : const {};
    final lpEnabled = (lp["enabled"] is bool) ? (lp["enabled"] as bool) : true;
    final lpMax = (lp["max_chars"] is num) ? (lp["max_chars"] as num).toInt() : 240;
    final lpAllowAny = lp["allow_domains"];
    final lpAllow = (lpAllowAny is List)
        ? lpAllowAny.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList()
        : <String>["huggingface.co"];

    return RssSettings(
      feeds: feeds,
      fetchOnStart: fetch,
      maxCacheItems: maxItems.clamp(10, 500),
      lookbackDays: lb.clamp(1, 3650),
      readKeepMax: keep.clamp(100, 200000),
      linkPreviewEnabled: lpEnabled,
      linkPreviewMaxChars: lpMax.clamp(60, 1000),
      linkPreviewAllowDomains: lpAllow,
    );
  }
}

class RssItem {
  final String feedId;
  final String sourceHost; // ex: "huggingface.co"
  final String itemId; // stable id (guid/link/id)
  final String title;
  final String link;
  final DateTime? publishedAt;
  String summary;
  RssItem({
    required this.feedId,
    required this.sourceHost,
    required this.itemId,
    required this.title,
    required this.link,
    required this.publishedAt,
    required this.summary,
  });

  Map<String, dynamic> toJson() => {
        "feed_id": feedId,
        "source_host": sourceHost,
        "item_id": itemId,
        "title": title,
        "link": link,
        "published_at": publishedAt?.toIso8601String(),
        "summary": summary,
      };

  static RssItem? fromJson(dynamic j) {
    if (j is! Map) return null;
    return RssItem(
      feedId: (j["feed_id"] ?? "").toString(),
      sourceHost: (j["source_host"] ?? "").toString(),
      itemId: (j["item_id"] ?? "").toString(),
      title: (j["title"] ?? "").toString(),
      link: (j["link"] ?? "").toString(),
      publishedAt: (j["published_at"] is String) ? DateTime.tryParse(j["published_at"]) : null,
      summary: (j["summary"] ?? "").toString(),
    );
  }
}

class RssCache {
  List<RssItem> items; // newest lastでもOK。ここは簡単に。
  RssCache(this.items);

  Map<String, dynamic> toJson() => {"items": items.map((e) => e.toJson()).toList()};

  static RssCache fromJson(dynamic j) {
    if (j is! Map) return RssCache([]);
    final a = j["items"];
    if (a is! List) return RssCache([]);
    return RssCache(a.map(RssItem.fromJson).whereType<RssItem>().toList());
  }
}

class RssState {
  final int v;
  DateTime? lastFetchAtUtc;

  // url-hash -> iso8601 utc (last seen publishedAt)
  final Map<String, String> lastSeenByFeed;

  // newest last
  final List<String> readItemIds;

  RssState({
    required this.v,
    required this.lastFetchAtUtc,
    required this.lastSeenByFeed,
    required this.readItemIds,
  });

  static RssState empty() => RssState(
        v: 1,
        lastFetchAtUtc: null,
        lastSeenByFeed: {},
        readItemIds: [],
      );

  bool isRead(String itemId) => readItemIds.contains(itemId);

  void markRead(String itemId, {required int keepMax}) {
    if (itemId.trim().isEmpty) return;
    if (readItemIds.contains(itemId)) return;
    readItemIds.add(itemId);
    if (readItemIds.length > keepMax) {
      final drop = readItemIds.length - keepMax;
      readItemIds.removeRange(0, drop);
    }
  }

  Map<String, dynamic> toJson() => {
        "v": v,
        "last_fetch_at_utc": lastFetchAtUtc?.toIso8601String(),
        "last_seen_by_feed": lastSeenByFeed,
        "read_item_ids": readItemIds,
      };

  static RssState fromJson(dynamic j) {
    if (j is! Map) return RssState.empty();
    final m = (j["last_seen_by_feed"] is Map) ? (j["last_seen_by_feed"] as Map) : const {};
    final lastSeen = <String, String>{};
    for (final e in m.entries) {
      lastSeen[e.key.toString()] = e.value.toString();
    }
    final readAny = j["read_item_ids"];
    final read = (readAny is List) ? readAny.map((e) => e.toString()).toList() : <String>[];
    final ts = (j["last_fetch_at_utc"] is String) ? DateTime.tryParse(j["last_fetch_at_utc"]) : null;
    return RssState(
      v: 1,
      lastFetchAtUtc: ts,
      lastSeenByFeed: lastSeen,
      readItemIds: read,
    );
  }
}

// ----- helpers -----

String _stripTags(String s) => s.replaceAll(RegExp(r"<[^>]*>"), " ").replaceAll(RegExp(r"\s+"), " ").trim();

DateTime? _parseRssDate(String? s) {
  if (s == null) return null;
  final t = s.trim();
  // RSS pubDate often RFC822. HttpDate.parse handles many common formats.
  try {
    return HttpDate.parse(t).toLocal();
  } catch (_) {}
  // Atom updated is often ISO8601
  return DateTime.tryParse(t)?.toLocal();
}
