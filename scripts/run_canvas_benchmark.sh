#!/usr/bin/env bash
# Native profile measurements in an isolated display, using Mesa software GL.
# Compilation is additional to the bounded (<55 s) active integration test.
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ECAD_FLUTTER_BIN="${ECAD_FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "$ECAD_FLUTTER_BIN" ]]; then
  printf '%s\n' 'Flutter was not found. Add flutter/bin to PATH or set ECAD_FLUTTER_BIN.' >&2
  exit 127
fi
cd -- "$PROJECT_DIR"
mkdir -p artifacts/performance

if ! command -v xvfb-run >/dev/null 2>&1; then
  printf '%s\n' 'xvfb-run is required to isolate the benchmark from the desktop.' >&2
  exit 1
fi

{
  printf '%s\n' 'Rendering: isolated Xvfb X11 display; LIBGL_ALWAYS_SOFTWARE=1.'
  printf '%s\n' 'These measurements describe this software-rendered run, not a GPU performance guarantee.'
  uname -srvmo
  "$ECAD_FLUTTER_BIN" --no-version-check --suppress-analytics --version
  if command -v lscpu >/dev/null 2>&1; then lscpu; fi
} > artifacts/performance/environment.txt

xvfb-run -a -s '-screen 0 1440x900x24' \
  env -u WAYLAND_DISPLAY GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 \
  "$ECAD_FLUTTER_BIN" --no-version-check --suppress-analytics drive \
    --profile -d linux \
    --driver=test_driver/performance_driver.dart \
    --target=integration_test/canvas_performance_test.dart \
    --dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false \
    '--dart-define=BENCHMARK_ENV=Linux / isolated Xvfb / Mesa software GL (LIBGL_ALWAYS_SOFTWARE=1)' \
    "$@"
