#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Launch the host desktop. Extra arguments are forwarded to `flutter run`.
# Set ECAD_FLUTTER_BIN to an executable when the SDK is not on PATH.
set -euo pipefail

ECAD_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ECAD_PROJECT_DIR"

if [[ -n "${ECAD_FLUTTER_BIN:-}" ]]; then
  ECAD_SDK_COMMAND="$(command -v -- "$ECAD_FLUTTER_BIN" || true)"
elif command -v flutter >/dev/null 2>&1; then
  ECAD_SDK_COMMAND="$(command -v flutter)"
else
  ECAD_SDK_COMMAND=''
  for candidate in \
    "$ECAD_PROJECT_DIR/.fvm/flutter_sdk/bin/flutter" \
    "$HOME/flutter/bin/flutter" \
    "$HOME/development/flutter/bin/flutter" \
    "$HOME/snap/flutter/common/flutter/bin/flutter" \
    /opt/flutter/bin/flutter; do
    if [[ -x "$candidate" ]]; then
      ECAD_SDK_COMMAND="$candidate"
      break
    fi
  done
fi

if [[ -z "$ECAD_SDK_COMMAND" ]]; then
  printf '%s\n' 'Flutter was not found. Install Flutter 3.47.7, add flutter/bin to PATH, or set ECAD_FLUTTER_BIN.' >&2
  exit 127
fi

case "$(uname -s)" in
  Linux*) ECAD_DEVICE=linux ;;
  Darwin*) ECAD_DEVICE=macos ;;
  MINGW*|MSYS*|CYGWIN*) ECAD_DEVICE=windows ;;
  *) printf '%s\n' 'Unsupported host. Use flutter run with an explicit device.' >&2; exit 1 ;;
esac

exec "$ECAD_SDK_COMMAND" --no-version-check --suppress-analytics run -d "$ECAD_DEVICE" "$@"
