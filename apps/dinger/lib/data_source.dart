// Pulls last night's real lines for a set of favorite players from the MLB
// Stats API, and fetches real highlight links on demand. No invented stats.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import 'mlb_client.dart';
import 'models.dart';

/// Your favorites. Resolved to MLB person ids at runtime, so spelling just has
/// to match MLB's roster (accents optional). Anyone not in MLB is skipped.
const List<String> kFavorites = <String>[
  'Shohei Ohtani',
  'Mookie Betts',
  'Roman Anthony',
  'Wilyer Abreu',
  'Kyle Schwarber',
  'Bryce Harper',
  'Munetaka Murakami',
  'Bobby Witt Jr.',
  'Oneil Cruz',
  'Yordan Alvarez',
  'Mike Trout',
];

/// MLB Film Room reels — the official destination when a specific clip isn't
/// found for a game.
const String kFilmRoomReels = 'https://www.mlb.com/video/topic/mlb-film-room-reels';

class LineupService {
  LineupService({MlbStatsClient? client})
      : _mlb = client ?? MlbStatsClient();

  final MlbStatsClient _mlb;

  /// Each favorite's most recent real game. Falls back to last season in the
  /// offseason so there's always real data to show; the real game date is
  /// displayed per card.
  Future<Lineup> loadLatest() async {
    final tracer = OTel.tracer();
    final span = tracer.startSpan('load_lineup');
    try {
      return await tracer.withSpanAsync(span, _loadLatest);
    } catch (e, st) {
      span.recordException(e, stackTrace: st);
      span.setStatus(SpanStatusCode.Error, e.toString());
      rethrow;
    } finally {
      span.end();
    }
  }

  Future<Lineup> _loadLatest() async {
    final now = DateTime.now();
    final season = now.year;
    final ids = await _mlb.resolveIds(kFavorites, season);

    final games = <GamePerformance>[];
    for (final name in kFavorites) {
      final id = ids[name];
      if (id == null) continue; // not in MLB — skip, never fabricate
      final game = await _mlb.latestGame(id, name, season) ??
          await _mlb.latestGame(id, name, season - 1);
      if (game != null) games.add(game);
    }

    // Most recent games first.
    games.sort((a, b) => b.date.compareTo(a.date));
    final label = games.isEmpty ? 'No games found' : 'Latest games';
    return Lineup(label: label, games: games);
  }

  Future<List<Highlight>> highlightsFor(GamePerformance p) async {
    final gamePk = p.gamePk;
    if (gamePk == null) return const [];
    final tracer = OTel.tracer();
    final span = tracer.startSpan(
      'load_highlights',
      attributes: OTel.attributesFromMap(<String, Object>{
        'app.player': p.player,
        'mlb.game_pk': gamePk,
      }),
    );
    try {
      return await tracer.withSpanAsync(
        span,
        () => _mlb.highlights(gamePk, p.playerId),
      );
    } catch (e, st) {
      span.recordException(e, stackTrace: st);
      span.setStatus(SpanStatusCode.Error, e.toString());
      return const [];
    } finally {
      span.end();
    }
  }
}
