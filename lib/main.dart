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

  AppConfig({
    required this.geminiApiKey,
    required this.idleTalkMinSec,
    required this.idleTalkMaxSec,
  });
}

// ===== Models =====

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
  final Emotion emotion;
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
        emotion = Emotion.idle,
        choiceProfile = ChoiceProfile.idleDefault,
        choices = const [],
        debugLineId = "fallback.local";

  Map<String, dynamic> toLogJson() => {
        "v": v,
        "text": text.length > 240 ? "${text.substring(0, 240)}…" : text,
        "emotion": emotion.name,
        "choice_profile": _choiceProfileToWire(choiceProfile),
        "choices": choices
            .map((c) => {"id": c.id, "label": c.label, "intent": _intentToWire(c.intent)})
            .toList(),
        "debug_line_id": debugLineId,
      };

  static Emotion parseEmotion(String s) {
    switch (s) {
      case "happy":
        return Emotion.happy;
      case "annoyed":
        return Emotion.annoyed;
      case "think":
        return Emotion.think;
      case "idle":
      default:
        return Emotion.idle;
    }
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
  final Map<Emotion, SpritePair> sprites;
  final Emotion defaultEmotion;
  final ChoiceProfile defaultChoiceProfile;
  final String systemPrompt;

  MascotPack({
    required this.id,
    required this.name,
    required this.windowSize,
    required this.sprites,
    required this.defaultEmotion,
    required this.defaultChoiceProfile,
    required this.systemPrompt,
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
        PopupMenuItem<String>(
          value: "exit",
          child: Text("終了"),
        ),
      ],
    );

    if (selected == "exit") {
      await windowManager.close();
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

  Future<MascotPack> _loadMascotPack(Directory dir) async {
    final manifestFile = File(p.join(dir.path, "manifest.json"));
    final systemPromptFile = File(p.join(dir.path, "system_prompt.txt"));

    final manifest = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    final systemPrompt = await systemPromptFile.readAsString();

    final id = manifest["id"] as String;
    final name = manifest["name"] as String;
    final window = manifest["window"] as Map<String, dynamic>;
    final width = (window["width"] as num).toDouble();
    final height = (window["height"] as num).toDouble();

    final sprites = <Emotion, SpritePair>{};
    final spritesJson = manifest["sprites"] as Map<String, dynamic>;
    SpritePair readPair(String key) {
      final m = spritesJson[key] as Map<String, dynamic>;
      return SpritePair(
        closedPath: p.join(dir.path, m["closed"] as String),
        openPath: p.join(dir.path, m["open"] as String),
      );
    }

    sprites[Emotion.idle] = readPair("idle");
    sprites[Emotion.happy] = readPair("happy");
    sprites[Emotion.annoyed] = readPair("annoyed");
    sprites[Emotion.think] = readPair("think");

    final defEmotion = MascotTurn.parseEmotion(manifest["default_emotion"] as String);
    final defProfile = MascotTurn.parseChoiceProfile(manifest["default_choice_profile"] as String);

    return MascotPack(
      id: id,
      name: name,
      windowSize: Size(width, height),
      sprites: sprites,
      defaultEmotion: defEmotion,
      defaultChoiceProfile: defProfile,
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

      // idle interval
      int readInt(String k, int def) {
        final v = obj[k];
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v.trim()) ?? def;
        return def;
      }

      final minSec = readInt("idle_talk_min_sec", 30);
      final maxSec = readInt("idle_talk_max_sec", 90);

      // clamp & sanitize (シンプル安全柵)
      final safeMin = minSec.clamp(3, 24 * 60 * 60);
      final safeMax = maxSec.clamp(safeMin, 24 * 60 * 60);

      return AppConfig(
        geminiApiKey: key,
        idleTalkMinSec: safeMin,
        idleTalkMaxSec: safeMax,
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
      await _doGeminiIdleTalk();
      _scheduleNextIdle();
    });
  }

  Future<void> _doLocalIdleTalk() async {
    final text = _localFallbackPool[Random().nextInt(_localFallbackPool.length)];
    final t = MascotTurn(
      v: 1,
      text: text,
      emotion: Emotion.think,
      choiceProfile: _pack?.defaultChoiceProfile ?? ChoiceProfile.idleDefault,
      choices: const [],
      debugLineId: "idle.local",
    );

    setState(() => _turn = t);
    _startMouthFlap();
    await _logEvent("turn", {"mode": "idle", "turn": t.toLogJson()});
  }

  Future<void> _doGeminiIdleTalk() async {
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
      );

      setState(() => _turn = t);
      _startMouthFlap();
      await _logEvent("turn", {"mode": "idle", "turn": t.toLogJson()});
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
    await _doGeminiIdleTalk();
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
      await _doGeminiIdleTalk();
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

  Map<String, dynamic> _mascotTurnSchema() {
    // response_schema は curl例のように大文字Typeを使う形式で合わせます。:contentReference[oaicite:3]{index=3}
    return {
      "type": "OBJECT",
      "properties": {
        "v": {"type": "INTEGER"},
        "text": {"type": "STRING"},
        "emotion": {
          "type": "STRING",
          "enum": ["idle", "happy", "annoyed", "think"]
        },
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
        "responseJsonSchema": _mascotTurnSchema(),
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
    b.writeln("CHOICE_PROFILE_HINT: ${mode == "idle" ? "idle_default" : "none"}");
    if (lastIntentWire != null) b.writeln("LAST_INTENT: $lastIntentWire");
    if (lastMascotText != null) b.writeln("LAST_MASCOT_TEXT: $lastMascotText");
    if (topic != null) {
      b.writeln("TOPIC_TITLE: ${topic["title"] ?? ""}");
      b.writeln("TOPIC_SNIPPET: ${topic["snippet"] ?? ""}");
      b.writeln("TOPIC_URL: ${topic["url"] ?? ""}");
    }
    b.writeln("");
    b.writeln("次の1ターンをJSONで返して。textは短く、URLは入れない。");
    return b.toString();
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
