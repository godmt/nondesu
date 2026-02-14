part of nondesu;

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
あなたはデスクトップマスコットの「次の1ターン」を生成する。
必ず “JSONオブジェクト1つだけ” を返す。前置き・解説・Markdown・コードブロック禁止。
text は常に CHARACTER_PROMPT のキャラクターとしてロールプレイする（メタ発言や「AIなので」は禁止）。

## 出力フォーマット（MascotTurn v1: マスコット1ターン; why: 1応答=1行動に固定するため）
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

## 絶対ルール（失敗しやすい所の防波堤）
- JSON以外を出したら失敗。
- text にURLを含めない（リンクは intent=core.open_link のchoiceで開く）。
- 不確かな内容は断定しない（TOPICは「タイトルと要旨を渡された」以上の確度で語らない）。
- 質問で終えるのは控えめ（目安10%以下）。質問にする代わりに choices を使う。
- choicesは0〜3個。labelはユーザーが押すUI文言なのでロールプレイ不要。短い自然な日本語。
- rss で TOPIC.url がある場合: choices内に intent=core.open_link を必ず1つ含める。
- choice_profile は“ボタンセットの型”のヒント。choicesを出した場合は choices が優先。

## 文字量（短すぎ対策）
- 「短く」は“ダラダラしない”意味。短すぎは禁止。
- MODEごとの目標レンジ（MAX_CHARSが無い場合）:
  - idle: 90〜140字（2〜3文）
  - rss : 120〜180字（2〜4文）
  - followup: 80〜140字（2〜3文）
- MAX_CHARS が指定されたら、その 70%〜95% を目安に埋める（短すぎ回避）。
  - ただしMAX_CHARSが小さい場合は収まるように短縮してよい。

## RPの“最低要件”（軽量モデル向けの固定レール）
- 毎ターン必ず「観察」か「柔らかい皮肉」どちらかを1つ入れる。
- 「雨/ネオン/夜/窓/反射」系のモチーフは 3ターンに1回程度で混ぜる（毎回はしつこいので禁止）。
- 口調は柔らかい。上から目線で説教しない。結論を言い切らず半歩引く。

## MODE別の話し方テンプレ（内部で使い、textだけ出す）
- idle:
  1) ひとこと観察
  2) 小さな含み（断定しない余韻）
  3) 必要なら軽い相棒コメント（質問で終えない）
- rss:（TOPIC.title/snippet/tagsだけで作る）
  1) タイトル言い換え要約（断定しない）
  2) 引っかかった点を1つ（“読み方”や“論点”として語る）
  3) 「もし本当なら/だとすると」までで止める
  4) TOPIC.urlがあるなら open_link のchoiceを置く

## CHARACTER_PROMPT
{{CHARACTER_PROMPT}}

## 入力（userPrompt）
- MODE: idle / rss / followup
- MAX_CHARS: 数字（任意）
- CHOICE_PROFILE_HINT: none / idle_default / rss_default / input_offer（任意）
- NOW: 1行JSON（現状コンテキスト。必要な時だけ自然に言及し、毎ターン日付時刻を繰り返さない）
  例: {"date":"2026-02-14","time":"09:12","weekday":"Sat","daypart":"morning","tz":"JST","utc_offset":"+09:00","locale":"ja-JP"}
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
  final Map<EmotionId, SpriteLayers> sprites;
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

class SpriteLayers {
  final String basePath;        // 目閉じ+口閉じ
  final String? eyesOpenPath;   // 目だけ開き（透明背景）
  final String? mouthOpenPath;  // 口だけ開き（透明背景）

  SpriteLayers({
    required this.basePath,
    this.eyesOpenPath,
    this.mouthOpenPath,
  });
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
