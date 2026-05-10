#!/usr/bin/env bash
#
# tool/try-dot-shorthands.sh
#
# Creates a branch and applies Dart 3.11+ dot-shorthand notation
# (`.foo` instead of `EnumType.foo`) to high-confidence call sites
# in the demo's production code (`lib/`, `bin/`). Skips test code
# because `expect(actual, matcher)` takes Object? for the matcher
# position — there's no context type for the compiler to infer
# from, so the syntax wouldn't compile there.
#
# Run from the repository root:
#
#   bash tool/try-dot-shorthands.sh
#
# What it does:
#   1. git checkout -b try/dot-shorthands (errors if it exists)
#   2. Bumps every pubspec.yaml's `sdk: ^3.10.0` constraint to
#      `^3.11.0` (dot-shorthands GA'd in 3.11).
#   3. Applies a small set of conservative regex transformations
#      to .dart files under lib/ and bin/.
#   4. Runs `dart analyze` and `dart test` and reports.
#   5. If analyze + tests pass, leaves the changes staged for
#      review (does NOT commit — you decide whether to keep).
#
# Reverting:
#   git checkout main && git branch -D try/dot-shorthands
#
# Safe by construction: if any transformation produces invalid code,
# `dart analyze` reports it and you can decide whether to fix or
# revert. The script never touches files outside lib/ and bin/.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v dart >/dev/null 2>&1; then
  echo "error: 'dart' is not on PATH." >&2
  exit 1
fi

# Refuse to run on a dirty tree — the user would lose track of what
# this script changed vs what they were already working on.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree is dirty. Commit or stash first." >&2
  exit 1
fi

BRANCH="try/dot-shorthands"
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "error: branch $BRANCH already exists. Delete it first:" >&2
  echo "       git branch -D $BRANCH" >&2
  exit 1
fi

echo "==> creating branch $BRANCH"
git checkout -b "$BRANCH"

echo "==> bumping SDK constraint to ^3.11.0 in all pubspec.yaml files"
find packages services apps -name pubspec.yaml -type f | while read -r f; do
  # Only bump the demo's own packages (sdk: ^3.10.0). Leave anything
  # else (vendored deps, fixtures) untouched.
  if grep -q 'sdk: \^3\.10\.0' "$f"; then
    sed -i '' 's/sdk: \^3\.10\.0/sdk: ^3.11.0/g' "$f"
    echo "    bumped: $f"
  fi
done

echo "==> applying dot-shorthand transformations to lib/ and bin/"

# We target only positions where the context type is unambiguous so
# the compiler can infer the enum type. The patterns:
#
#   1. Named arguments where the parameter is typed:
#        kind: SpanKind.server  →  kind: .server
#
#   2. Positional first argument to setStatus(SpanStatusCode, [String?]):
#        setStatus(SpanStatusCode.Ok)  →  setStatus(.Ok)
#        ..setStatus(SpanStatusCode.Error, e.toString())
#                                         ↓
#        ..setStatus(.Error, e.toString())
#
#   3. Return statements where the function declares a return type:
#        return SpanStatusCode.Error;  →  return .Error;
#
# Tests are deliberately skipped — `expect(actual, matcher)` doesn't
# propagate `actual`'s static type to `matcher`, so a bare `.Error`
# in the matcher position has no context type and won't compile.

apply_transforms() {
  local f="$1"

  # 1. Named arg: `kind: SpanKind.X`
  sed -i '' -E 's/\bkind: SpanKind\.([A-Za-z][A-Za-z0-9]*)/kind: .\1/g' "$f"

  # 2. setStatus(SpanStatusCode.X — both the call form and the
  #    cascade form. The status-code first arg is positional, type
  #    SpanStatusCode.
  sed -i '' -E 's/setStatus\(SpanStatusCode\.([A-Za-z][A-Za-z0-9]*)/setStatus(.\1/g' "$f"

  # 3. Return statements: `return SpanStatusCode.X;`
  sed -i '' -E 's/return SpanStatusCode\.([A-Za-z][A-Za-z0-9]*);/return .\1;/g' "$f"
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
if dart analyze 2>&1 | tee /tmp/try-dot-shorthands-analyze.log; then
  echo "    analyze: OK"
else
  echo "    analyze: FAIL — see /tmp/try-dot-shorthands-analyze.log"
fi

echo "==> dart test"
if dart test 2>&1 | tail -5 | tee /tmp/try-dot-shorthands-test.log; then
  echo "    test: OK"
else
  echo "    test: FAIL — see /tmp/try-dot-shorthands-test.log"
fi

echo
echo "Done. Branch '$BRANCH' has the changes staged but uncommitted."
echo "Review with:    git diff"
echo "Keep & commit:  git add -A && git commit -m 'try: dot shorthands'"
echo "Discard:        git checkout main && git branch -D $BRANCH"
