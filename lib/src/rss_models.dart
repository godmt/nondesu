part of nondesu;

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
