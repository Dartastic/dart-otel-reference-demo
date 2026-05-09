#!/usr/bin/env bash
#
# tool/coverage.sh
#
# Run the test suite for every package in the Dart workspace and produce
# a unified LCOV coverage report at coverage/lcov.info. With --html, also
# render an HTML report at coverage/html/ using `genhtml` (from `lcov`).
#
# Run from the repository root.
#
# Usage:
#   tool/coverage.sh           # produce coverage/lcov.info
#   tool/coverage.sh --html    # also produce coverage/html/index.html
#
# Requirements:
#   - dart (Dart SDK)
#   - lcov, for the optional --html flag (`brew install lcov` /
#     `apt-get install lcov`)
#
# The script activates `package:coverage` globally on first run; subsequent
# runs reuse the activated version.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COVERAGE_DIR="${ROOT_DIR}/coverage"
LCOV_FILE="${COVERAGE_DIR}/lcov.info"

WANT_HTML=0
for arg in "$@"; do
  case "$arg" in
    --html) WANT_HTML=1 ;;
    -h|--help)
      sed -n '3,20p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "error: unknown argument '$arg'" >&2
      exit 2
      ;;
  esac
done

# Discover workspace member packages with a `test` directory.
mapfile -t TESTABLE_PACKAGES < <(
  find "${ROOT_DIR}/packages" "${ROOT_DIR}/services" "${ROOT_DIR}/apps" \
    -maxdepth 2 -name pubspec.yaml -print 2>/dev/null \
    | while read -r pubspec; do
        pkg_dir="$(dirname "$pubspec")"
        if [ -d "${pkg_dir}/test" ] && \
           find "${pkg_dir}/test" -name '*_test.dart' -print -quit | grep -q .; then
          echo "$pkg_dir"
        fi
      done
)

if [ "${#TESTABLE_PACKAGES[@]}" -eq 0 ]; then
  echo "error: no member packages with tests were found" >&2
  exit 1
fi

echo "==> packages with tests:"
for pkg in "${TESTABLE_PACKAGES[@]}"; do
  echo "    $(realpath --relative-to="$ROOT_DIR" "$pkg")"
done

# Ensure the `coverage` package is globally activated.
if ! dart pub global list 2>/dev/null | grep -q '^coverage '; then
  echo "==> activating package:coverage globally"
  dart pub global activate coverage >/dev/null
fi

# Workspace-wide pub get so all packages resolve.
echo "==> dart pub get (workspace)"
( cd "$ROOT_DIR" && dart pub get >/dev/null )

mkdir -p "$COVERAGE_DIR"
rm -f "$LCOV_FILE"
touch "$LCOV_FILE"

# Run tests with coverage in each package, then format and append to the
# unified LCOV file. Per-package working dir is required because
# `package_config.json` and source paths are resolved relative to the
# package, not the workspace root.
for pkg in "${TESTABLE_PACKAGES[@]}"; do
  rel="$(realpath --relative-to="$ROOT_DIR" "$pkg")"
  pkg_coverage="${pkg}/coverage"
  pkg_lcov="${pkg_coverage}/lcov.info"

  echo
  echo "==> $rel: dart test --coverage"
  rm -rf "$pkg_coverage"
  ( cd "$pkg" && dart test --coverage="${pkg_coverage}" )

  echo "==> $rel: format_coverage -> lcov"
  ( cd "$pkg" && dart pub global run coverage:format_coverage \
      --lcov \
      --in="${pkg_coverage}" \
      --out="${pkg_lcov}" \
      --report-on=lib \
      --packages=.dart_tool/package_config.json \
  )

  if [ -s "$pkg_lcov" ]; then
    cat "$pkg_lcov" >> "$LCOV_FILE"
  fi
done

LINES_REPORTED=$(grep -c '^DA:' "$LCOV_FILE" || true)
echo
echo "==> wrote $LCOV_FILE ($LINES_REPORTED line records)"

if [ "$WANT_HTML" -eq 1 ]; then
  if ! command -v genhtml >/dev/null 2>&1; then
    echo "error: --html requires lcov's 'genhtml'." >&2
    echo "  macOS:  brew install lcov" >&2
    echo "  Linux:  sudo apt-get install lcov" >&2
    exit 1
  fi
  HTML_DIR="${COVERAGE_DIR}/html"
  rm -rf "$HTML_DIR"
  echo "==> genhtml -> ${HTML_DIR}"
  genhtml --quiet --output-directory "$HTML_DIR" "$LCOV_FILE"
  echo "==> open $(realpath --relative-to="$ROOT_DIR" "$HTML_DIR")/index.html"
fi
