#!/usr/bin/env bash
#
# tool/build.sh
#
# Top-level build verification for the Dart OTel demo. Runs the same
# checks CI would: workspace pub-get, analyzer, formatter check, and
# the test suite. With --release, additionally AOT-compiles each
# service binary under services/ to confirm the deployable artifact
# builds.
#
# Run from anywhere — the script chdir's to the repository root.
#
# Usage:
#   tool/build.sh [--release] [--no-format] [--no-test]
#
# Flags:
#   --release    AOT-compile every service binary to verify the
#                deployable artifact builds. Output goes to
#                build/<service>/.
#   --no-format  Skip `dart format --set-exit-if-changed`. Useful when
#                you have unstaged formatting changes you intend to
#                commit separately.
#   --no-test    Skip `dart test`. Useful for a fast sanity-check.
#
# Exit code: 0 on success, non-zero on any failed step (the script
# stops at the first failure).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DO_RELEASE=0
DO_FORMAT=1
DO_TEST=1
for arg in "$@"; do
  case "$arg" in
    --release)   DO_RELEASE=1 ;;
    --no-format) DO_FORMAT=0 ;;
    --no-test)   DO_TEST=0 ;;
    -h|--help)
      sed -n '3,28p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "error: unknown argument '$arg'" >&2
      exit 2
      ;;
  esac
done

if ! command -v dart >/dev/null 2>&1; then
  echo "error: 'dart' is not on PATH. Install the Dart SDK and retry." >&2
  exit 1
fi

step() { printf '\n==> %s\n' "$1"; }

# Workspace members from the root pubspec's `workspace:` list. Splitting on
# Flutter membership lets `dart test`/`dart format` handle the pure-Dart
# members while Flutter apps go through `flutter test`. Adding a member to
# the workspace list is all that's needed — no edits here. (apps/dinger is
# deliberately NOT a workspace member — it carries path deps outside the
# repo — so it is never swept.)
DART_MEMBERS=()
FLUTTER_MEMBERS=()
while IFS= read -r member; do
  [ -f "$ROOT_DIR/$member/pubspec.yaml" ] || continue
  if grep -qE '^[[:space:]]*sdk:[[:space:]]*flutter' "$ROOT_DIR/$member/pubspec.yaml"; then
    FLUTTER_MEMBERS+=("$member")
  else
    DART_MEMBERS+=("$member")
  fi
done < <(
  sed -n '/^workspace:/,/^[^[:space:]#-]/{/^[[:space:]]*-[[:space:]]/p;}' \
      "$ROOT_DIR/pubspec.yaml" \
    | sed -E 's/^[[:space:]]*-[[:space:]]*//'
)

step "dart pub get (workspace)"
dart pub get

step "dart analyze (workspace)"
dart analyze

if [ "$DO_FORMAT" -eq 1 ]; then
  step "dart format --set-exit-if-changed"
  # Ignore generated files and the .dart_tool directory. `dart format`
  # respects analysis_options.yaml's exclude rules already, so this
  # mostly just constrains the search root.
  dart format --set-exit-if-changed --output=none \
      "${DART_MEMBERS[@]}" "${FLUTTER_MEMBERS[@]}" || {
    echo
    echo "error: code is not formatted. Run 'dart format .' to fix." >&2
    exit 1
  }
else
  echo "(skipping format check)"
fi

if [ "$DO_TEST" -eq 1 ]; then
  # Pure-Dart members run under the VM test runner in one process; Flutter
  # members need `flutter test` (the VM runner can't load flutter_test).
  step "dart test (Dart members)"
  dart test "${DART_MEMBERS[@]}"
  for member in "${FLUTTER_MEMBERS[@]}"; do
    [ -d "$ROOT_DIR/$member/test" ] || continue
    step "flutter test ($member)"
    ( cd "$ROOT_DIR/$member" && flutter test )
  done
else
  echo "(skipping tests)"
fi

if [ "$DO_RELEASE" -eq 1 ]; then
  # Discover executable entry points: every services/<name>/bin/*.dart
  # and apps/<name>/bin/*.dart. Dart convention is that bin/ contains
  # only entry points, so anything in those directories is a build
  # target. Adding a new service or app needs no script changes.
  mapfile -t ENTRIES < <(
    find "$ROOT_DIR/services" "$ROOT_DIR/apps" \
        -maxdepth 3 -type f -path '*/bin/*.dart' 2>/dev/null \
      | sort
  )
  if [ "${#ENTRIES[@]}" -eq 0 ]; then
    echo "(no bin/*.dart entry points found under services/ or apps/ — skipping release compile)"
  else
    mkdir -p "$ROOT_DIR/build"
    for entry in "${ENTRIES[@]}"; do
      # services/foo/bin/server.dart  -> pkg=foo, exe=foo
      # apps/bar/bin/baz.dart         -> pkg=bar, exe=baz
      pkg_dir="$(dirname "$(dirname "$entry")")"
      pkg="$(basename "$pkg_dir")"
      exe="$(basename "$entry" .dart)"
      out="$ROOT_DIR/build/$pkg"
      mkdir -p "$out"
      step "dart compile exe -> build/$pkg/$exe"
      dart compile exe "$entry" -o "$out/$exe"
    done
  fi
fi

echo
echo "==> build OK"
