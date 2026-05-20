// Live data from the public MLB Stats API (https://statsapi.mlb.com).
//
// Every request is wrapped in an OpenTelemetry client span, so the network
// calls show up in the same trace as the Genkit flow in Dartastic Hosted.
//
// Note: the MLB Stats API and MLB video are for personal, non-commercial use.
// We read box-score stats and highlight *metadata*, and we LINK to MLB's own
// video player (mlb.com / Film Room) — we never re-host or embed their video.

import 'dart:convert';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

class MlbStatsClient {
  MlbStatsClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;
  static const String _base = 'https://statsapi.mlb.com/api/v1';

  // name (normalized) -> player id, loaded once per season.
  Map<String, int>? _idIndex;

  void close() => _http.close();

  Future<Map<String, Object?>> _getJson(String path, String spanName) async {
    final tracer = OTel.tracer();
    final span = tracer.startSpan(
      spanName,
      attributes: OTel.attributesFromMap(<String, Object>{
        'http.request.method': 'GET',
        'url.full': '$_base$path',
        'server.address': 'statsapi.mlb.com',
      }),
    );
    try {
      final res = await tracer.withSpanAsync(
        span,
        () => _http.get(Uri.parse('$_base$path')),
      );
      if (res.statusCode != 200) {
        throw http.ClientException(
          'MLB Stats API ${res.statusCode} for $path',
        );
      }
      return jsonDecode(res.body) as Map<String, Object?>;
    } catch (e, st) {
      span.recordException(e, stackTrace: st);
      span.setStatus(SpanStatusCode.Error, e.toString());
      rethrow;
    } finally {
      span.end();
    }
  }

  /// Resolves a list of player names to MLB person ids. Names that don't match
  /// an active player (e.g. someone not in MLB) are simply omitted — we never
  /// fabricate an id.
  Future<Map<String, int>> resolveIds(
    List<String> names,
    int season,
  ) async {
    _idIndex ??= await _loadPlayerIndex(season);
    final index = _idIndex!;
    final out = <String, int>{};
    for (final name in names) {
      final key = _norm(name);
      final id = index[key] ??
          _firstWhereOrNull(index.entries, (e) => e.key.contains(key))?.value;
      if (id != null) out[name] = id;
    }
    return out;
  }

  Future<Map<String, int>> _loadPlayerIndex(int season) async {
    final json =
        await _getJson('/sports/1/players?season=$season', 'mlb.players_index');
    final people = (json['people'] as List?) ?? const [];
    final map = <String, int>{};
    for (final p in people.cast<Map<String, Object?>>()) {
      final id = (p['id'] as num?)?.toInt();
      final name = p['fullName'] as String?;
      if (id != null && name != null) map[_norm(name)] = id;
    }
    return map;
  }

  /// The player's most recent game this season (their "last night", when they
  /// played last night). Returns null if they have no games logged.
  Future<GamePerformance?> latestGame(
    int playerId,
    String playerName,
    int season,
  ) async {
    final json = await _getJson(
      '/people/$playerId/stats?stats=gameLog&group=hitting&season=$season',
      'mlb.gamelog',
    );
    final stats = (json['stats'] as List?) ?? const [];
    if (stats.isEmpty) return null;
    final splits =
        ((stats.first as Map)['splits'] as List?)?.cast<Map<String, Object?>>();
    if (splits == null || splits.isEmpty) return null;
    // gameLog is chronological; the last entry is the most recent game.
    return GamePerformance.fromGameLogSplit(
      splits.last,
      playerId: playerId,
      player: playerName,
    );
  }

  /// Real highlight clips for a game, preferring ones tagged with the player.
  /// We return metadata + a link to MLB's own video page.
  Future<List<Highlight>> highlights(int gamePk, int playerId) async {
    final json = await _getJson('/game/$gamePk/content', 'mlb.game_content');
    final items = (((json['highlights'] as Map?)?['highlights'] as Map?)?[
            'items'] as List?)
        ?.cast<Map<String, Object?>>();
    if (items == null || items.isEmpty) return const [];

    bool tagsPlayer(Map<String, Object?> item) {
      final kws = (item['keywordsAll'] as List?)?.cast<Map<String, Object?>>() ??
          const [];
      return kws.any((k) =>
          (k['type'] as String?)?.contains('player') == true &&
          '${k['value']}' == '$playerId');
    }

    final matching = items.where(tagsPlayer).toList();
    final chosen = matching.isNotEmpty ? matching : items.take(1).toList();
    return chosen.take(5).map(_toHighlight).toList();
  }

  Highlight _toHighlight(Map<String, Object?> item) {
    final slug = item['slug'] as String? ?? '';
    String? thumb;
    final image = item['image'];
    if (image is Map) {
      final cuts = image['cuts'];
      if (cuts is List && cuts.isNotEmpty && cuts.first is Map) {
        thumb = (cuts.first as Map)['src'] as String?;
      } else if (cuts is Map && cuts.isNotEmpty) {
        final first = cuts.values.first;
        if (first is Map) thumb = first['src'] as String?;
      }
    }
    return Highlight(
      title: item['title'] as String? ??
          item['headline'] as String? ??
          'Highlight',
      blurb: item['blurb'] as String? ?? item['description'] as String? ?? '',
      mlbUrl: slug.isEmpty
          ? 'https://www.mlb.com/video'
          : 'https://www.mlb.com/video/$slug',
      thumbnailUrl: thumb,
      durationSeconds: _parseDuration(item['duration'] as String?),
    );
  }

  static int? _parseDuration(String? d) {
    if (d == null) return null;
    final parts = d.split(':').map(int.tryParse).toList();
    if (parts.any((p) => p == null)) return null;
    final nums = parts.cast<int>();
    if (nums.length == 3) return nums[0] * 3600 + nums[1] * 60 + nums[2];
    if (nums.length == 2) return nums[0] * 60 + nums[1];
    if (nums.length == 1) return nums[0];
    return null;
  }

  // Accent-insensitive, lowercased key for name matching (e.g. "Yordan
  // Álvarez" == "Yordan Alvarez").
  static String _norm(String s) {
    const map = {
      'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a',
      'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
      'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
      'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
      'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
      'ñ': 'n', 'ç': 'c',
    };
    final lower = s.toLowerCase().trim();
    final sb = StringBuffer();
    for (final ch in lower.split('')) {
      sb.write(map[ch] ?? ch);
    }
    return sb.toString();
  }

  static MapEntry<K, V>? _firstWhereOrNull<K, V>(
    Iterable<MapEntry<K, V>> it,
    bool Function(MapEntry<K, V>) test,
  ) {
    for (final e in it) {
      if (test(e)) return e;
    }
    return null;
  }
}
