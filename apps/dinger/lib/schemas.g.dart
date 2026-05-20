// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'schemas.dart';

// **************************************************************************
// SchemaGenerator
// **************************************************************************

/// Tool input: which player to look up.
base class PlayerQuery {
  /// Creates a [PlayerQuery] from a JSON map.
  factory PlayerQuery.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  PlayerQuery._(this._json);

  PlayerQuery({required String player}) {
    _json = {'player': player};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [PlayerQuery].
  static const SchemanticType<PlayerQuery> $schema = _PlayerQueryTypeFactory();

  String get player {
    return _json['player'] as String;
  }

  set player(String value) {
    _json['player'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [PlayerQuery] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _PlayerQueryTypeFactory extends SchemanticType<PlayerQuery> {
  const _PlayerQueryTypeFactory();

  @override
  PlayerQuery parse(Object? json) {
    return PlayerQuery._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'PlayerQuery',
    definition: $Schema
        .object(properties: {'player': $Schema.string()}, required: ['player'])
        .value,
    dependencies: [],
  );
}

/// Structured output the model must return — no free-text parsing.
base class Recap {
  /// Creates a [Recap] from a JSON map.
  factory Recap.fromJson(Map<String, dynamic> json) => $schema.parse(json);

  Recap._(this._json);

  Recap({
    required String headline,
    required String body,
    required String funFact,
  }) {
    _json = {'headline': headline, 'body': body, 'funFact': funFact};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [Recap].
  static const SchemanticType<Recap> $schema = _RecapTypeFactory();

  /// A short, punchy headline.
  String get headline {
    return _json['headline'] as String;
  }

  /// A short, punchy headline.
  set headline(String value) {
    _json['headline'] = value;
  }

  /// Two fun sentences recapping the game, grounded in the real box score.
  String get body {
    return _json['body'] as String;
  }

  /// Two fun sentences recapping the game, grounded in the real box score.
  set body(String value) {
    _json['body'] = value;
  }

  /// One surprising or fun fact tied to the line.
  String get funFact {
    return _json['funFact'] as String;
  }

  /// One surprising or fun fact tied to the line.
  set funFact(String value) {
    _json['funFact'] = value;
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [Recap] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _RecapTypeFactory extends SchemanticType<Recap> {
  const _RecapTypeFactory();

  @override
  Recap parse(Object? json) {
    return Recap._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'Recap',
    definition: $Schema
        .object(
          properties: {
            'headline': $Schema.string(),
            'body': $Schema.string(),
            'funFact': $Schema.string(),
          },
          required: ['headline', 'body', 'funFact'],
        )
        .value,
    dependencies: [],
  );
}
