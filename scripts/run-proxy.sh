#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root/proxy"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else "Python 3.12+ is required. Install it and make it your python3 command.")'
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
.venv/bin/python -m pip install -q -r requirements.txt
if [[ ! -f .env ]]; then
  cp .env.example .env
  .venv/bin/python - <<'PY'
from pathlib import Path
import secrets
path = Path('.env')
path.write_text(path.read_text().replace('APP_KEY=\n', 'APP_KEY=' + secrets.token_urlsafe(32) + '\n'))
path.chmod(0o600)
PY
  echo 'Created proxy/.env with a generated app key. Add your Plaid Sandbox client ID and secret, then rerun.'
  exit 1
fi
.venv/bin/python - <<'PY'
from app import Settings
settings = Settings.from_env()
settings.validate()
if not settings.configured and not (settings.ship24_api_key and len(settings.app_key) >= 32):
    raise SystemExit('Set Plaid Sandbox credentials or SHIP24_API_KEY, plus a 32-character APP_KEY, in proxy/.env.')
if settings.environment != 'sandbox':
    raise SystemExit('This launch script is for Sandbox only.')
PY
exec .venv/bin/python -m uvicorn app:app --host 127.0.0.1 --port "${MONARCH_PROXY_PORT:-8000}" --no-access-log --no-proxy-headers --log-level warning
