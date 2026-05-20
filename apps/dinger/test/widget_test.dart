// Unit tests for Dinger's pure-Dart parsing/logic (no network/Genkit needed).
// The sample below mirrors the real MLB Stats API gameLog split shape.

import 'package:dinger/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromGameLogSplit parses the real MLB shape', () {
    final p = GamePerformance.fromGameLogSplit(
      const {
        'date': '2025-09-28',
        'isWin': true,
        'isHome': false,
        'team': {'name': 'Los Angeles Dodgers'},
        'opponent': {'name': 'Seattle Mariners'},
        'game': {'gamePk': 776139},
        'stat': {
          'summary': '3-5 | HR, 2B, 2 K',
          'atBats': 5,
          'hits': 3,
          'homeRuns': 1,
          'rbi': 1,
          'runs': 2,
          'doubles': 1,
          'strikeOuts': 2,
        },
      },
      playerId: 660271,
      player: 'Shohei Ohtani',
    );

    expect(p.player, 'Shohei Ohtani');
    expect(p.homeRuns, 1);
    expect(p.hits, 3);
    expect(p.gamePk, 776139);
    expect(p.result, 'W');
    expect(p.matchup, '@ Seattle Mariners');
    expect(p.toPromptLine(), contains('Ohtani'));
    expect(p.toPromptLine(), contains('2025-09-28'));
  });

  test('headline reflects the standout stat', () {
    GamePerformance perf({int hr = 0, int hits = 0, int sb = 0, int rbi = 0}) {
      return GamePerformance(
        playerId: 1,
        player: 'Test Player',
        team: 'LAD',
        opponent: 'ARI',
        date: '2025-09-28',
        isWin: true,
        isHome: true,
        gamePk: 1,
        summary: '$hits-4',
        atBats: 4,
        hits: hits,
        homeRuns: hr,
        rbi: rbi,
        runs: 0,
        doubles: 0,
        triples: 0,
        walks: 0,
        strikeOuts: 0,
        stolenBases: sb,
      );
    }

    expect(perf(hr: 2).headline(), contains('goes deep'));
    expect(perf(hr: 1).headline(), contains('goes yard'));
    expect(perf(hits: 3).headline(), contains('rakes'));
    expect(perf(sb: 1).headline(), contains('swipes'));
    expect(perf(rbi: 3).headline(), contains('drives in'));
  });
}
