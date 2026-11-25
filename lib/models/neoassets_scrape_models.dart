/// Data types of the NeoAssets scraping API (`/api/v1/scrape/*`).
library;

/// Why a NeoAssets request failed, in terms the UI can act on.
enum NeoAssetsScrapeFailure {
  /// This build carries no NeoAssets developer application.
  notConfigured,

  /// The personal API key is unknown or revoked.
  invalidKey,

  /// The account's email address has not been verified yet.
  emailNotVerified,

  /// NeoStation's developer application was refused or revoked.
  appRejected,

  /// Today's quota is used up; it resets at [NeoAssetsScrapeException.resetsAt].
  /// Only older servers with a daily cap send this.
  quotaExceeded,

  /// Rate, concurrency or server-busy refusal that outlasted the retries.
  retryLater,

  /// The server could not be reached.
  network,

  /// The request was malformed (e.g. an unknown system).
  badRequest,

  unknown,
}

class NeoAssetsScrapeException implements Exception {
  final NeoAssetsScrapeFailure failure;
  final String message;
  final DateTime? resetsAt;

  const NeoAssetsScrapeException(
    this.failure, {
    this.message = '',
    this.resetsAt,
  });

  /// Failures that make every further request of a session pointless.
  bool get stopsSession =>
      failure == NeoAssetsScrapeFailure.quotaExceeded ||
      failure == NeoAssetsScrapeFailure.invalidKey ||
      failure == NeoAssetsScrapeFailure.emailNotVerified ||
      failure == NeoAssetsScrapeFailure.appRejected ||
      failure == NeoAssetsScrapeFailure.notConfigured;

  @override
  String toString() =>
      'NeoAssetsScrapeException($failure${message.isEmpty ? '' : ': $message'})';
}

/// The signed-in NeoAssets user (`GET /api/v1/scrape/account`).
class NeoAssetsAccount {
  /// Empty for a guest.
  final String username;

  /// Whether NeoAssets sees this session as a guest: the app's credentials
  /// with no personal key, on the guest allowance.
  final bool isGuest;

  /// Concurrent requests the account may run, set by its rank.
  final int threads;

  /// Requests per minute the account may make; 0 when the server did not
  /// say (older servers).
  final int ratePerMinute;

  /// Whether NeoAssets puts no daily cap on the account's lookups.
  final bool unlimited;

  /// Lookups allowed per day, or null when there is no daily cap.
  final int? dailyLimit;

  /// Lookups made today.
  final int used;
  final DateTime? resetsAt;

  const NeoAssetsAccount({
    required this.username,
    this.isGuest = false,
    required this.threads,
    this.ratePerMinute = 0,
    this.unlimited = false,
    this.dailyLimit,
    required this.used,
    this.resetsAt,
  });

  factory NeoAssetsAccount.fromJson(Map<String, dynamic> json) {
    final user = json['user'] is Map ? json['user'] as Map : const {};
    final quota = json['quota'] is Map ? json['quota'] as Map : const {};
    return NeoAssetsAccount(
      username: user['username']?.toString() ?? '',
      isGuest: json['subject'] == 'guest',
      // Guests have no user; newer servers send the threads alongside.
      threads: _int(user['threads'] ?? json['threads'], 1),
      ratePerMinute: _int(json['rate_per_minute'], 0),
      unlimited: quota['unlimited'] == true,
      dailyLimit: _nullableInt(quota['daily_limit']),
      used: _int(quota['used'], 0),
      resetsAt: DateTime.tryParse(quota['resets_at']?.toString() ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
    'subject': isGuest ? 'guest' : 'user',
    'user': isGuest ? null : {'username': username, 'threads': threads},
    'threads': threads,
    'rate_per_minute': ratePerMinute,
    'quota': {
      'unlimited': unlimited,
      'daily_limit': dailyLimit,
      'used': used,
      'resets_at': resetsAt?.toIso8601String(),
    },
  };

  /// Whether lookups have no daily cap: the server says so, or sends no
  /// positive limit.
  bool get hasNoDailyLimit =>
      unlimited || dailyLimit == null || dailyLimit! <= 0;

  /// Whether the key belongs to a user (a guest has no username).
  bool get isUser => username.isNotEmpty;
}

/// One media file of a game, served from the NeoAssets CDN.
class NeoAssetsMedia {
  /// `cover`, `boxfront`, `boxback`, `screenshot`, `logo`, `fanart` or `video`.
  final String kind;
  final String url;
  final String mime;

  /// Release region of a regional cover or logo; empty for the rest.
  final String region;

  const NeoAssetsMedia({
    required this.kind,
    required this.url,
    required this.mime,
    this.region = '',
  });

  factory NeoAssetsMedia.fromJson(Map<String, dynamic> json) => NeoAssetsMedia(
    kind: json['kind']?.toString() ?? '',
    url: json['url']?.toString() ?? '',
    mime: json['mime']?.toString() ?? '',
    region: json['region']?.toString() ?? '',
  );

  /// File extension for [mime], falling back to the URL's.
  String get extension {
    switch (mime) {
      case 'image/webp':
        return 'webp';
      case 'image/png':
        return 'png';
      case 'image/jpeg':
        return 'jpg';
      case 'video/mp4':
        return 'mp4';
      case 'video/webm':
        return 'webm';
    }
    final path = Uri.tryParse(url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    return dot == -1 ? '' : path.substring(dot + 1).toLowerCase();
  }
}

/// A game as NeoAssets returns it from `GET /api/v1/scrape/games`.
class NeoAssetsGame {
  final String id;
  final String name;

  /// Title per release region (`Japan` → its Japanese title), when NeoAssets
  /// knows more than the primary [name].
  final Map<String, String> regionalNames;
  final String systemId;
  final String? developer;
  final String? publisher;
  final String? genre;

  /// 0..10, 0 meaning unrated.
  final int rating;
  final int? releaseYear;
  final int? releaseMonth;

  /// Description per language code; untranslated languages are left out.
  final Map<String, String> descriptions;
  final List<NeoAssetsMedia> media;

  /// `hash` or `name`: how the server matched the ROM.
  final String matchedBy;

  const NeoAssetsGame({
    required this.id,
    required this.name,
    this.regionalNames = const {},
    required this.systemId,
    this.developer,
    this.publisher,
    this.genre,
    this.rating = 0,
    this.releaseYear,
    this.releaseMonth,
    this.descriptions = const {},
    this.media = const [],
    this.matchedBy = '',
  });

  factory NeoAssetsGame.fromJson(
    Map<String, dynamic> json, {
    Object? matchedBy,
  }) {
    final descriptions = <String, String>{};
    json.forEach((key, value) {
      if (key.startsWith('description_') && value is String) {
        final text = value.trim();
        if (text.isNotEmpty) {
          descriptions[key.substring('description_'.length)] = text;
        }
      }
    });
    final media = json['media'] is List
        ? (json['media'] as List)
              .whereType<Map<String, dynamic>>()
              .map(NeoAssetsMedia.fromJson)
              .where((m) => m.url.isNotEmpty)
              .toList()
        : const <NeoAssetsMedia>[];
    final regionalNames = <String, String>{};
    if (json['names'] is List) {
      for (final entry in (json['names'] as List).whereType<Map>()) {
        final region = entry['region']?.toString() ?? '';
        final name = entry['name']?.toString().trim() ?? '';
        if (region.isNotEmpty && name.isNotEmpty) regionalNames[region] = name;
      }
    }
    return NeoAssetsGame(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      regionalNames: regionalNames,
      systemId: json['system_id']?.toString() ?? '',
      developer: _text(json['developer']),
      publisher: _text(json['publisher']),
      genre: _text(json['genre']),
      rating: _int(json['rating'], 0),
      releaseYear: _nullableInt(json['release_year']),
      releaseMonth: _nullableInt(json['release_month']),
      descriptions: descriptions,
      media: media,
      matchedBy: matchedBy?.toString() ?? '',
    );
  }

  /// The media file of [kind] for the first of [regions] that has one,
  /// else the first of that kind, or null.
  NeoAssetsMedia? firstMedia(String kind, {List<String> regions = const []}) {
    final ofKind = media.where((m) => m.kind == kind).toList();
    if (ofKind.isEmpty) return null;
    for (final region in regions) {
      for (final m in ofKind) {
        if (m.region.toLowerCase() == region.toLowerCase()) return m;
      }
    }
    return ofKind.first;
  }
}

/// How a NeoStation system is addressed in a NeoAssets lookup: a single
/// `system_id`, or a `group` of systems sharing one catalog (arcade sets).
class NeoAssetsSystemSelector {
  /// Query parameter name: `system_id` or `group`.
  final String param;
  final String value;

  const NeoAssetsSystemSelector.system(this.value) : param = 'system_id';
  const NeoAssetsSystemSelector.group(this.value) : param = 'group';

  @override
  bool operator ==(Object other) =>
      other is NeoAssetsSystemSelector &&
      other.param == param &&
      other.value == value;

  @override
  int get hashCode => Object.hash(param, value);

  @override
  String toString() => '$param=$value';
}

String? _text(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

int _int(Object? value, int fallback) => _nullableInt(value) ?? fallback;

int? _nullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
