part of nondesu;

class _SpeechBubble extends StatelessWidget {
  final String title;
  final String text;

  /// Optional context line shown near the top (e.g. RSS article title).
  final String? contextTitle;

  final List<MascotChoice> choices;
  final Future<void> Function(Intent) onChoice;

  /// True while waiting for Gemini. When true, choices are hidden and thinking dots are shown.
  final bool isThinking;

  const _SpeechBubble({
    required this.title,
    required this.text,
    required this.choices,
    required this.onChoice,
    this.contextTitle,
    this.isThinking = false,
  });

  static String _truncateLine(String s, int maxChars) {
    final t = s.trim();
    if (t.isEmpty) return "";
    if (t.length <= maxChars) return t;
    final cut = maxChars <= 1 ? 1 : maxChars - 1;
    return "${t.substring(0, cut)}…";
  }

  @override
  Widget build(BuildContext context) {
    final ct = (contextTitle ?? "").trim();
    final showContextTitle = ct.isNotEmpty;
    final showChoices = choices.isNotEmpty && !isThinking;
    final showText = text.trim().isNotEmpty || !isThinking;

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

            if (showContextTitle) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "📰 ${_truncateLine(ct, 56)}",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],

            if (showText) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  text,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],

            if (isThinking) ...[
              const SizedBox(height: 10),
              const Center(child: _ThinkingDots()),
            ],

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
                        child: Text(c.label, overflow: TextOverflow.ellipsis, maxLines: 1),
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

class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final v = _ctrl.value; // 0..1
        final n = (v * 3).floor() % 4; // 0..3
        const dotsArr = ["", ".", "..", "..."];
        final dots = dotsArr[n];
        final padded = dots.padRight(3, " ");
        return Text(
          "……$padded",
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        );
      },
    );
  }
}
