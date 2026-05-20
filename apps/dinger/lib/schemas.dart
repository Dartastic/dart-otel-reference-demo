// Genkit/schemantic schemas for tool input and structured output.
// Run `dart run build_runner build` to (re)generate schemas.g.dart.

import 'package:schemantic/schemantic.dart';

part 'schemas.g.dart';

/// Tool input: which player to look up.
@Schema()
abstract class $PlayerQuery {
  String get player;
}

/// Structured output the model must return — no free-text parsing.
@Schema()
abstract class $Recap {
  /// A short, punchy headline.
  String get headline;

  /// Two fun sentences recapping the game, grounded in the real box score.
  String get body;

  /// One surprising or fun fact tied to the line.
  String get funFact;
}
