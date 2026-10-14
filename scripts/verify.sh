#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Verify the Flutter app and the independently usable Dart model/CLI package.
# Builds and native performance benchmarks are separate, explicit steps.
set -euo pipefail

ECAD_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ECAD_PROJECT_DIR"
ECAD_SDK_COMMAND="${ECAD_FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "$ECAD_SDK_COMMAND" ]]; then
  for candidate in \
    "$ECAD_PROJECT_DIR/.fvm/flutter_sdk/bin/flutter" \
    "$HOME/flutter/bin/flutter" \
    "$HOME/development/flutter/bin/flutter" \
    "$HOME/snap/flutter/common/flutter/bin/flutter" \
    /opt/flutter/bin/flutter; do
    if [[ -x "$candidate" ]]; then ECAD_SDK_COMMAND="$candidate"; break; fi
  done
fi
if [[ -z "$ECAD_SDK_COMMAND" ]] || ! command -v -- "$ECAD_SDK_COMMAND" >/dev/null 2>&1; then
  printf '%s\n' 'Flutter was not found. Set ECAD_FLUTTER_BIN or add flutter/bin to PATH.' >&2
  exit 127
fi

# Resolve symlinks portably, including Flutter installed through a package manager.
ECAD_FLUTTER_PATH="$(command -v -- "$ECAD_SDK_COMMAND")"
while [[ -L "$ECAD_FLUTTER_PATH" ]]; do
  ECAD_LINK_DIR="$(cd -P -- "$(dirname -- "$ECAD_FLUTTER_PATH")" && pwd)"
  ECAD_LINK_TARGET="$(readlink "$ECAD_FLUTTER_PATH")"
  if [[ "$ECAD_LINK_TARGET" = /* ]]; then
    ECAD_FLUTTER_PATH="$ECAD_LINK_TARGET"
  else
    ECAD_FLUTTER_PATH="$ECAD_LINK_DIR/$ECAD_LINK_TARGET"
  fi
done
ECAD_DART_COMMAND="$(dirname -- "$ECAD_FLUTTER_PATH")/dart"
if [[ ! -x "$ECAD_DART_COMMAND" ]]; then
  ECAD_DART_COMMAND="$(command -v dart || true)"
fi
if [[ -z "$ECAD_DART_COMMAND" ]]; then
  printf '%s\n' 'The Dart executable bundled with Flutter was not found.' >&2
  exit 127
fi

"$ECAD_SDK_COMMAND" --no-version-check --suppress-analytics pub get
(
  cd packages/ecad_core
  "$ECAD_DART_COMMAND" pub get
)
"$ECAD_SDK_COMMAND" --no-version-check --suppress-analytics analyze --no-pub
"$ECAD_SDK_COMMAND" --no-version-check --suppress-analytics test --no-pub --reporter expanded
(
  cd packages/ecad_core
  "$ECAD_DART_COMMAND" analyze --fatal-infos
  "$ECAD_DART_COMMAND" test --reporter expanded
)

if [[ -x "$ECAD_PROJECT_DIR/.venv-pdf/bin/python" || -n "${ECAD_PDF_PYTHON:-}" ]]; then
  "${ECAD_PDF_PYTHON:-$ECAD_PROJECT_DIR/.venv-pdf/bin/python}" -I scripts/test_import_pdf.py
else
  printf '%s\n' 'Optional PDF converter tests skipped: install .venv-pdf as documented in docs/pdf-import.md.'
fi
