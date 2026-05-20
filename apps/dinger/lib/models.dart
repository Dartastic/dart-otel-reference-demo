// Domain models for Dinger. All stats come straight from the MLB Stats API
// gameLog — nothing here is invented.

/// One player's box-score line for a single real game.
class GamePerformance {
  const GamePerformance({
    required this.playerId,
    required this.player,
    required this.team,
    required this.opponent,
    required this.date,
    required this.isWin,
    required this.isHome,
    required this.gamePk,
    required this.summary,
    required this.atBats,
    required this.hits,
    required this.homeRuns,
    required this.rbi,
    required this.runs,
    required this.doubles,
    required this.triples,
    required this.walks,
    required this.strikeOuts,
    required this.stolenBases,
  });

  final int playerId;
  final String player;
  final String team;
  final String opponent;
  final String date; // YYYY-MM-DD, the real game date
  final bool isWin;
  final bool isHome;
  final int? gamePk; // links to /game/{gamePk}/content for highlights
  final String summary; // MLB's own line, e.g. "3-5 | HR, 2B, 2 K"
  final int atBats;
  final int hits;
  final int homeRuns;
  final int rbi;
  final int runs;
  final int doubles;
  final int triples;
  final int walks;
  final int strikeOuts;
  final int stolenBases;

  /// Builds from one MLB Stats API gameLog split. The split carries team,
  /// opponent, date, isWin, gamePk and the stat block; player name + id are
  /// passed in from the lookup that fetched the log.
  factory GamePerformance.fromGameLogSplit(
    Map<String, Object?> split, {
    required int playerId,
    required String player,
  }) {
    final stat = (split['stat'] as Map?)?.cast<String, Object?>() ?? const {};
    int n(String k) => (stat[k] as num?)?.toInt() ?? 0;
    String teamName(String key) =>
        (split[key] as Map?)?['name'] as String? ?? '';
    return GamePerformance(
      playerId: playerId,
      player: player,
      team: teamName('team'),
      opponent: teamName('opponent'),
      date: split['date'] as String? ?? '',
      isWin: split['isWin'] == true,
      isHome: split['isHome'] == true,
      gamePk: ((split['game'] as Map?)?['gamePk'] as num?)?.toInt(),
      summary: stat['summary'] as String? ?? '',
      atBats: n('atBats'),
      hits: n('hits'),
      homeRuns: n('homeRuns'),
      rbi: n('rbi'),
      runs: n('runs'),
      doubles: n('doubles'),
      triples: n('triples'),
      walks: n('baseOnBalls'),
      strikeOuts: n('strikeOuts'),
      stolenBases: n('stolenBases'),
    );
  }

  String get result => isWin ? 'W' : 'L';
  String get matchup => isHome ? 'vs $opponent' : '@ $opponent';

  /// Compact, model-friendly description fed to the Genkit flow.
  String toPromptLine() =>
      '$player ($team) $matchup on $date — $summary. Team ${isWin ? 'won' : 'lost'}.';

  /// Deterministic headline from the real stat line.
  String headline() {
    if (homeRuns >= 2) return '$player goes deep ${homeRuns}x';
    if (homeRuns == 1) return '$player goes yard';
    if (hits >= 3) return '$player rakes — $hits hits';
    if (stolenBases > 0) return '$player swipes a bag';
    if (rbi >= 2) return '$player drives in $rbi';
    return '$player takes the field';
  }
}

/// A real MLB highlight clip (metadata only — we link to MLB's player, we do
/// not re-host or embed their video).
class Highlight {
  const Highlight({
    required this.title,
    required this.blurb,
    required this.mlbUrl,
    required this.thumbnailUrl,
    required this.durationSeconds,
  });

  final String title;
  final String blurb;
  final String mlbUrl; // https://www.mlb.com/video/{slug}
  final String? thumbnailUrl;
  final int? durationSeconds;
}

/// A night's slate of live performances.
class Lineup {
  const Lineup({required this.label, required this.games});

  final String label; // e.g. "Latest games" / the date
  final List<GamePerformance> games;
}
