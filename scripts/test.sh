#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root/MonarchCore"
swift test
cd "$task_root/proxy"
if [[ ! -d .venv ]]; then python3 -m venv .venv; fi
.venv/bin/python -m pip install -q -r requirements-dev.txt
.venv/bin/python -m pytest -q
