part of nondesu;

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
