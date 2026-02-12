part of nondesu;

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
