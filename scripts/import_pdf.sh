#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Convert a PDF into an Open ECAD graphics-only project (offline, read-only on
# the PDF). Usage: scripts/import_pdf.sh input.pdf output.oecad [--pages 1,3-5]
# [--report report.json]
# Python lookup order: $ECAD_PDF_PYTHON, then <project>/.venv-pdf/bin/python.
# This wrapper never installs packages and never touches the network; see
# scripts/import_pdf_requirements.txt for the optional (AGPL) PyMuPDF setup.
set -euo pipefail

ECAD_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${ECAD_PDF_PYTHON:-}" ]]; then
  ECAD_PDF_PYTHON_BIN="$(command -v -- "$ECAD_PDF_PYTHON" || true)"
  if [[ -z "$ECAD_PDF_PYTHON_BIN" || ! -x "$ECAD_PDF_PYTHON_BIN" ]]; then
    printf '%s\n' "ECAD_PDF_PYTHON is set but is not an executable Python: $ECAD_PDF_PYTHON" >&2
    exit 127
  fi
elif [[ -x "$ECAD_PROJECT_DIR/.venv-pdf/bin/python" ]]; then
  ECAD_PDF_PYTHON_BIN="$ECAD_PROJECT_DIR/.venv-pdf/bin/python"
else
  cat >&2 <<'MESSAGE'
No Python with PyMuPDF was found. Set ECAD_PDF_PYTHON to a Python that has
PyMuPDF 1.26.7, or create .venv-pdf yourself (nothing is installed for you):
  python3 -m venv .venv-pdf
  .venv-pdf/bin/pip install -r scripts/import_pdf_requirements.txt
PyMuPDF is AGPL-licensed and is an optional, separate dependency.
MESSAGE
  exit 127
fi

# -I: ignore PYTHON* variables and the current directory, so nothing beside
# the (untrusted) input can shadow a module.
exec "$ECAD_PDF_PYTHON_BIN" -I "$ECAD_PROJECT_DIR/scripts/import_pdf.py" "$@"
