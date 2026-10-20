#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# verify-staging-redis-security.sh
# Validates Staging Docker Compose Redis authentication & secrets configuration (#956)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

COMPOSE_FILE="${ROOT_DIR}/docker-compose.staging.yml"
ENV_EXAMPLE="${ROOT_DIR}/.env.staging.example"
BACKEND_ENV="${ROOT_DIR}/backend/.env.staging"
INDEXER_ENV="${ROOT_DIR}/indexer/.env.staging"

echo "=========================================================="
echo "  Staging Redis Password & Secrets Security Verification  "
echo "=========================================================="

# 1. Check docker-compose.staging.yml contains requirepass ${REDIS_PASSWORD}
echo -n "[1/5] Checking Redis requirepass directive in compose... "
if grep -Eq 'command:\s*redis-server\s+--requirepass\s+\$\{REDIS_PASSWORD\}' "${COMPOSE_FILE}"; then
  echo "OK (requirepass \${REDIS_PASSWORD} present)"
else
  echo "FAILED: docker-compose.staging.yml is missing 'redis-server --requirepass \${REDIS_PASSWORD}'"
  exit 1
fi

# 2. Check healthcheck uses authenticated ping
echo -n "[2/5] Checking Redis authenticated healthcheck... "
if grep -Eq 'REDISCLI_AUTH|redis-cli\s+-a' "${COMPOSE_FILE}"; then
  echo "OK (authenticated healthcheck configured)"
else
  echo "FAILED: docker-compose.staging.yml healthcheck is unauthenticated"
  exit 1
fi

# 3. Check backend & indexer pass REDIS_PASSWORD and authenticated REDIS_URL
echo -n "[3/5] Checking backend and indexer compose env bindings... "
if grep -Fq 'REDIS_PASSWORD=${REDIS_PASSWORD}' "${COMPOSE_FILE}" && \
   grep -Fq 'REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379' "${COMPOSE_FILE}"; then
  echo "OK (REDIS_PASSWORD and REDIS_URL bound)"
else
  echo "FAILED: docker-compose.staging.yml missing REDIS_PASSWORD / REDIS_URL service bindings"
  exit 1
fi

# 4. Check .env.staging.example has strong REDIS_PASSWORD placeholder
echo -n "[4/5] Checking .env.staging.example requirements... "
if grep -Eq '^REDIS_PASSWORD=.+' "${ENV_EXAMPLE}" && \
   grep -Eq '^REDIS_URL=redis://:\$\{REDIS_PASSWORD\}@redis:6379' "${ENV_EXAMPLE}"; then
  PASS_LEN=$(grep -E '^REDIS_PASSWORD=' "${ENV_EXAMPLE}" | cut -d'=' -f2- | tr -d '\r\n' | wc -c)
  if [ "${PASS_LEN}" -ge 32 ]; then
    echo "OK (REDIS_PASSWORD present with ${PASS_LEN}-char strong placeholder)"
  else
    echo "FAILED: REDIS_PASSWORD placeholder in .env.staging.example is too short (<32 chars)"
    exit 1
  fi
else
  echo "FAILED: .env.staging.example missing REDIS_PASSWORD or REDIS_URL"
  exit 1
fi

# 5. Check staging env files
echo -n "[5/5] Checking backend/.env.staging and indexer/.env.staging... "
if grep -Eq '^REDIS_PASSWORD=.+' "${BACKEND_ENV}" && \
   grep -Eq '^REDIS_PASSWORD=.+' "${INDEXER_ENV}"; then
  echo "OK (both backend and indexer staging envs include REDIS_PASSWORD)"
else
  echo "FAILED: backend or indexer staging env missing REDIS_PASSWORD"
  exit 1
fi

echo "=========================================================="
echo "  All 5/5 Staging Redis Security Verifications PASSED!    "
echo "=========================================================="
