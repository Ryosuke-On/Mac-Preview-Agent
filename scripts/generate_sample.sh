#!/usr/bin/env bash
# Generates docs/sample.pdf from scripts/sample.html using WebKit.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
mkdir -p "$ROOT/docs"
swift "$HERE/html2pdf.swift" "$HERE/sample.html" "$ROOT/docs/sample.pdf"
echo "Wrote $ROOT/docs/sample.pdf"
