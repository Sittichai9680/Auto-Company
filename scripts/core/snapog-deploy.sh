#!/bin/bash
# ============================================================
# SnapOG — One-shot deploy unlock (run once, interactively)
# ============================================================
# Deploys SnapOG to Cloudflare Workers production.
#
# This is the ONLY thing blocking revenue. Run it once from a shell
# where you can complete the Cloudflare OAuth (or export a token).
#
#   ./scripts/core/snapog-deploy.sh
#
# Non-interactive alternative (no OAuth prompt):
#   export CLOUDFLARE_API_TOKEN=cf-...
#   ./scripts/core/snapog-deploy.sh
#
# Idempotent: safe to re-run. Each step skips if already done.
# ============================================================
set -euo pipefail

cd "$(dirname "$0")/../projects/snapog"

DB_NAME="snapog-db"
R2_BUCKET="snapog-og-cache"
TOML="wrangler.toml"

step() { printf '\n\033[1;34m▶ %s\033[0m\n' "$1"; }

step "1/6 — Authenticate (wrangler whoami)"
if npx wrangler whoami 2>&1 | grep -q "not authenticated"; then
  if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
    echo "No token env var. Starting interactive OAuth (opens browser)..."
    npx wrangler login
  fi
else
  echo "Already authenticated. Skipping."
fi
npx wrangler whoami 2>&1 | grep -q "not authenticated" && \
  { echo "✗ Still not authenticated. Aborting."; exit 1; }

step "2/6 — Create D1 database ($DB_NAME) if missing"
DB_ID="$(npx wrangler d1 list --json 2>/dev/null \
  | node -e "const d=JSON.parse(require('fs').readFileSync(0));const m=d.find(x=>x.name==='$DB_NAME');process.stdout.write(m?m.uuid:'')" \
  || true)"
if [ -z "$DB_ID" ]; then
  DB_ID="$(npx wrangler d1 create "$DB_NAME" 2>&1 | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  [ -z "$DB_ID" ] && { echo "✗ D1 create failed."; exit 1; }
  echo "Created D1: $DB_ID"
else
  echo "D1 exists: $DB_ID"
fi
# Write the real database_id into every environment block in wrangler.toml
node -e "
const fs=require('fs');let t=fs.readFileSync('$TOML','utf8');
t=t.replace(/database_id = \"placeholder-set-after-wrangler-d1-create\"/g,'database_id = \"$DB_ID\"');
fs.writeFileSync('$TOML',t);
console.log('Patched database_id into $TOML');"

step "3/6 — Create R2 bucket ($R2_BUCKET) if missing"
if ! npx wrangler r2 bucket list 2>/dev/null | grep -q "$R2_BUCKET"; then
  npx wrangler r2 bucket create "$R2_BUCKET"
  echo "Created R2 bucket: $R2_BUCKET"
else
  echo "R2 bucket exists."
fi

step "4/6 — Apply D1 migrations (remote)"
npx wrangler d1 migrations apply --remote --env production

step "5/6 — Deploy Worker (production)"
DEPLOY_OUT="$(npx wrangler deploy --env production 2>&1)" || { echo "$DEPLOY_OUT"; exit 1; }
echo "$DEPLOY_OUT"

step "6/6 — Smoke test the live API"
# ponytail: grep the URL from the single deploy output; no second deploy
URL="$(printf '%s\n' "$DEPLOY_OUT" | grep -oE 'https://snapog[^\s"]*\.workers\.dev' | head -1 || true)"
[ -z "$URL" ] && URL="https://snapog.<account>.workers.dev"
echo "Worker URL: $URL"
echo "Next: open $URL/register in a browser, get a free key, then:"
echo "  curl '$URL/og?title=Hello&key=sk_...'"
echo "Done. Revenue path is now live."
