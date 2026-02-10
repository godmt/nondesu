import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Window init
  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(360, 520),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  // Acrylic (transparent)
  try {
    await Window.initialize();
    await Window.setEffect(effect: WindowEffect.transparent);
  } catch (_) {
    // 환경에 따라 실패할 수 있음. 실패해도 계속 진행.
  }

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

// ===== Home =====

class MascotHome extends StatefulWidget {
  const MascotHome({super.key});

  @override
  State<MascotHome> createState() => _MascotHomeState();
}

class _MascotHomeState extends State<MascotHome> with WindowListener {
  MascotPack? _pack;

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
    await windowManager.setSize(pack.windowSize);
    _scheduleNextIdle();
    setState(() {});
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
    final sec = 30 + Random().nextInt(61);
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

    final apiKey = _apiKeyFromEnv();
    if (apiKey == null || apiKey.trim().isEmpty) {
      setState(() => _turn = MascotTurn.fallback("GEMINI_API_KEY が無い。環境変数に入れてね。"));
      return;
    }

    try {
      final userPrompt = _buildUserPrompt(mode: "idle", maxChars: 70);
      final t = await _callGeminiTurn(
        apiKey: apiKey,
        model: "gemini-3-flash-preview",
        systemPrompt: pack.systemPrompt,
        userPrompt: userPrompt,
      );

      setState(() => _turn = t);
      _startMouthFlap();
      await _logEvent("turn", {"mode": "idle", "turn": t.toLogJson()});
    } catch (e) {
      setState(() => _turn = MascotTurn.fallback("…通信が荒れてる。${e.toString()}"));
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
      final dir = await getApplicationSupportDirectory();
      final logsDir = Directory(p.join(dir.path, "logs"));
      if (!logsDir.existsSync()) logsDir.createSync(recursive: true);

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
      // ignore
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
              onTap: _onAvatarTap,
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

          // Right click menu-like small button (PoC)
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              tooltip: "閉じる",
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => windowManager.close(),
            ),
          ),
        ],
      ),
    );
  }

  // === Gemini settings (super simple) ===
  // PoCなので「まずは環境変数」対応にします。
  // set GEMINI_API_KEY=... をWindowsで設定してから起動、が一番手軽。
  // もちろん後で入力UIにしてもOK。
  String? _apiKeyFromEnv() => Platform.environment["GEMINI_API_KEY"];

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
        "response_schema": _mascotTurnSchema(),
        "temperature": 1.0,
        "maxOutputTokens": 256
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

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = (decoded["candidates"] as List?) ?? [];
    if (candidates.isEmpty) throw Exception("No candidates");
    final content = (candidates[0] as Map<String, dynamic>)["content"] as Map<String, dynamic>;
    final parts = (content["parts"] as List).cast<Map<String, dynamic>>();
    final text = (parts.first["text"] as String?) ?? "";

    // response_mime_type=application/json でも text にJSON文字列で入る前提でパースします。
    final obj = jsonDecode(text) as Map<String, dynamic>;

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
