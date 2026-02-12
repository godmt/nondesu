part of nondesu;

class _AvatarSummary {
  final String id;
  final String name;
  final String description;
  final Directory dir;
  final String thumbnailPath; // absolute
  final Size windowSize;

  _AvatarSummary({
    required this.id,
    required this.name,
    required this.description,
    required this.dir,
    required this.thumbnailPath,
    required this.windowSize,
  });
}

class _AvatarPickerDialog extends StatelessWidget {
  final List<_AvatarSummary> avatars;
  final String? selectedId;

  const _AvatarPickerDialog({
    required this.avatars,
    required this.selectedId,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('アバター選択'),
      content: SizedBox(
        width: 560,
        height: 640,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'manifest.json の thumbnail（必須）と description（任意）を表示します。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: avatars.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final a = avatars[i];
                  final isSel = (a.id == selectedId);

                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.of(context).pop<_AvatarSummary>(a),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSel
                              ? Colors.white.withOpacity(0.9)
                              : Colors.white.withOpacity(0.25),
                          width: isSel ? 2 : 1,
                        ),
                        color: isSel
                            ? Colors.white.withOpacity(0.08)
                            : Colors.transparent,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(
                              File(a.thumbnailPath),
                              width: 72,
                              height: 72,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder: (_, __, ___) => Container(
                                width: 72,
                                height: 72,
                                alignment: Alignment.center,
                                color: Colors.white.withOpacity(0.08),
                                child: const Icon(Icons.image_not_supported),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  a.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (a.description.trim().isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    a.description.trim(),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.white.withOpacity(0.82),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 4),
                                Text(
                                  a.id,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withOpacity(0.55),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (isSel)
                            Icon(
                              Icons.check_circle,
                              size: 18,
                              color: Colors.white.withOpacity(0.85),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop<_AvatarSummary>(null),
          child: const Text('キャンセル'),
        ),
      ],
    );
  }
}
