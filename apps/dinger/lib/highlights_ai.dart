// The AI bit, done the Genkit way: a TOOL the model can call to fetch real MLB
// stats, a FLOW that orchestrates it, and STRUCTURED output (a typed Recap).
//
// With a Gemini key, `ai.generate` decides to call `getPlayerLastGame`, gets the
// real box score back, and returns a typed Recap. Without a key, the flow calls
// the same tool path directly and templates a Recap — so it still runs and still
// traces. Either way Genkit runs on Dartastic OpenTelemetry, so the flow, the
// tool call, and the model call all show up in Dartastic Hosted.

import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';

import 'mlb_client.dart';
import 'schemas.dart';

const String _geminiKey =
    String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');

class HighlightService {
  HighlightService._(this._ai, this._mlb, this.hasModel) {
    // Register the tool eagerly so the model can resolve it by name.
    _tool = _ai.defineTool(
      name: 'getPlayerLastGame',
      description:
          "Get a player's most recent real MLB box-score line (date, "
          'opponent, hits, home runs, RBI, etc.).',
      inputSchema: PlayerQuery.$schema,
      fn: (input, _) async => _fetchLine(input.player),
    );
  }

  factory HighlightService.create({MlbStatsClient? mlb}) {
    final hasModel = _geminiKey.isNotEmpty;
    final ai = hasModel
        ? Genkit(plugins: [googleAI(apiKey: _geminiKey)])
        : Genkit();
    return HighlightService._(ai, mlb ?? MlbStatsClient(), hasModel);
  }

  final Genkit _ai;
  final MlbStatsClient _mlb;
  final bool hasModel;
  late final Tool<PlayerQuery, String> _tool;

  // The flow: input = player name, structured output = Recap.
  late final _flow = _ai.defineFlow(
    name: 'playerHighlight',
    outputSchema: Recap.$schema,
    fn: (String player, context) async {
      if (hasModel) {
        final res = await _ai.generate(
          model: googleAI.gemini('gemini-2.5-flash'),
          prompt:
              'Write a fun MLB highlight recap for $player\'s most recent game. '
              'First call the getPlayerLastGame tool to fetch the real box '
              'score, then base the recap strictly on those real numbers. Keep '
              'the body to two punchy sentences. No hashtags or emoji.',
          toolNames: [_tool.name],
          outputSchema: Recap.$schema,
        );
        return res.output ?? _template(player, await _fetchLine(player));
      }
      // No key: exercise the tool path directly, then template a Recap.
      return _template(player, await _fetchLine(player));
    },
  );

  /// Runs the flow for a player and returns a UI-friendly recap.
  Future<Recap> generate(String player) => _flow(player);

  String get generatedBy => hasModel ? 'gemini (tool-calling)' : 'template';

  // Shared data path used by both the tool and the no-key fallback. Resolves
  // the name to an MLB id and pulls the most recent real game.
  Future<String> _fetchLine(String player) async {
    final season = DateTime.now().year;
    final ids = await _mlb.resolveIds([player], season);
    final id = ids[player];
    if (id == null) return 'No MLB player found named "$player".';
    final game = await _mlb.latestGame(id, player, season) ??
        await _mlb.latestGame(id, player, season - 1);
    return game?.toPromptLine() ?? 'No recent game found for $player.';
  }

  Recap _template(String player, String line) => Recap(
        headline: '$player — latest game',
        body: line,
        funFact: 'Set GEMINI_API_KEY to let Gemini write the hype via Genkit.',
      );
}
