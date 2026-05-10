#!/usr/bin/env bash
#
# tool/apply-dot-shorthands.sh
#
# Applies Dart 3.11+ dot-shorthand notation (`.foo` instead of
# `EnumType.foo`) at every high-confidence call site in the demo's
# production code. Skips test code because `expect(actual, matcher)`
# takes Object? for the matcher position — the static type isn't
# propagated, so a bare `.Error` there has no context type.
#
# Run from the repository root:
#
#   bash tool/apply-dot-shorthands.sh
#
# What it does:
#   1. Bumps every workspace pubspec's `sdk: ^3.10.0` constraint to
#      `^3.11.0` (dot shorthands GA'd in Dart 3.11).
#   2. Applies a set of regex transformations to .dart files under
#      `lib/` and `bin/` for every workspace package.
#   3. Runs `dart analyze` and reports.
#
# This script is idempotent — running it twice is a no-op.
#
# Patterns transformed (each safe because the parameter or
# return type is statically known at the call site):
#
#   - Named-arg with typed parameter:
#       kind: SpanKind.server                    →  kind: .server
#       kind: WeatherProviderErrorKind.badRequest → kind: .badRequest
#       weatherCode: WeatherCode.partlyCloudy    →  weatherCode: .partlyCloudy
#
#   - Positional first arg to setStatus(SpanStatusCode, [String?]):
#       setStatus(SpanStatusCode.Ok)             →  setStatus(.Ok)
#
#   - Return statements (function return type declared):
#       return SpanStatusCode.Error;             →  return .Error;
#       return WeatherProviderErrorKind.parse;   →  return .parse;
#
#   - Switch-expression arms inside functions whose declared
#     return type is the enum (we target the specific
#     `kindFromStatus`-shaped switches in this codebase):
#       400 => WeatherProviderErrorKind.badRequest,
#                                            →  400 => .badRequest,

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v dart >/dev/null 2>&1; then
  echo "error: 'dart' is not on PATH." >&2
  exit 1
fi

echo "==> bumping SDK constraint to ^3.11.0 in all pubspec.yaml files"
find packages services apps -name pubspec.yaml -type f | while read -r f; do
  if grep -q 'sdk: \^3\.10\.0' "$f"; then
    sed -i '' 's/sdk: \^3\.10\.0/sdk: ^3.11.0/g' "$f"
    echo "    bumped: $f"
  fi
done

echo "==> applying dot-shorthand transformations to lib/ and bin/"

apply_transforms() {
  local f="$1"

  # ── Named arguments where the parameter type is known.
  # `kind:` parameters: SpanKind on tracer.startSpan, and
  # WeatherProviderErrorKind on WeatherProviderException.
  sed -i '' -E 's/\bkind: SpanKind\.([A-Za-z][A-Za-z0-9]*)/kind: .\1/g' "$f"
  sed -i '' -E 's/\bkind: WeatherProviderErrorKind\.([A-Za-z][A-Za-z0-9]*)/kind: .\1/g' "$f"

  # `weatherCode:` parameters on CurrentWeather / DailyForecast.
  sed -i '' -E 's/\bweatherCode: WeatherCode\.([A-Za-z][A-Za-z0-9]*)/weatherCode: .\1/g' "$f"

  # ── setStatus(SpanStatusCode.X, ...) — first arg is positional,
  # type SpanStatusCode. Both call form and cascade form.
  sed -i '' -E 's/setStatus\(SpanStatusCode\.([A-Za-z][A-Za-z0-9]*)/setStatus(.\1/g' "$f"

  # ── Return statements with a declared enum return type.
  sed -i '' -E 's/return SpanStatusCode\.([A-Za-z][A-Za-z0-9]*);/return .\1;/g' "$f"
  sed -i '' -E 's/return WeatherProviderErrorKind\.([A-Za-z][A-Za-z0-9]*);/return .\1;/g' "$f"
  sed -i '' -E 's/return WeatherCode\.([A-Za-z][A-Za-z0-9]*);/return .\1;/g' "$f"

  # ── Switch-expression arms returning an enum from a function whose
  # return type is that enum. The patterns we target are written
  # in the form `<pattern> => Enum.value,` — the trailing comma
  # is what disambiguates a switch-arm from a regular expression.
  sed -i '' -E 's/=> WeatherProviderErrorKind\.([A-Za-z][A-Za-z0-9]*),/=> .\1,/g' "$f"
  sed -i '' -E 's/=> WeatherCode\.([A-Za-z][A-Za-z0-9]*),/=> .\1,/g' "$f"
  sed -i '' -E 's/=> SpanKind\.([A-Za-z][A-Za-z0-9]*),/=> .\1,/g' "$f"
  sed -i '' -E 's/=> SpanStatusCode\.([A-Za-z][A-Za-z0-9]*),/=> .\1,/g' "$f"
}

CHANGED=0
while IFS= read -r f; do
  before=$(md5 -q "$f")
  apply_transforms "$f"
  after=$(md5 -q "$f")
  if [ "$before" != "$after" ]; then
    CHANGED=$((CHANGED + 1))
    echo "    transformed: $f"
  fi
done < <(find packages services apps -type f -name '*.dart' \
           \( -path '*/lib/*' -o -path '*/bin/*' \))

echo "==> $CHANGED file(s) transformed"

echo "==> dart pub get (workspace)"
dart pub get >/dev/null

echo "==> dart analyze"
if dart analyze 2>&1 | grep -E '^\s+(error|warning)' >/tmp/dot-shorthands-issues; then
  echo
  echo "Errors / warnings:"
  cat /tmp/dot-shorthands-issues
  exit 1
fi
echo "    analyze: clean (only info-level lints, no errors or warnings)"
