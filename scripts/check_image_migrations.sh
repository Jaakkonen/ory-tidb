#!/usr/bin/env sh
# SPDX-License-Identifier: LicenseRef-Proprietary
# © CRACI Corporation Oy. All rights reserved.
#
# check_image_migrations.sh — run "migrate sql up" inside each Ory TiDB image
# against a live TiDB container and verify the exit code is 0.
#
# Unlike run_migrations.sh (which executes raw .sql files), this script tests
# the actual built binaries — catching DSN parsing bugs, missing dialect
# registrations, and other runtime failures that the SQL file test cannot.
#
# Usage:
#   sh scripts/check_image_migrations.sh [options]
#
# Options:
#   --kratos IMAGE   Kratos image to test  (default: ghcr.io/jaakkonen/ory-tidb-kratos:latest)
#   --keto   IMAGE   Keto image to test    (default: ghcr.io/jaakkonen/ory-tidb-keto:latest)
#   --hydra  IMAGE   Hydra image to test   (default: ghcr.io/jaakkonen/ory-tidb-hydra:latest)
#   --only   NAME    Only test one component (kratos|keto|hydra)
#
# Passing images locally:
#   sh scripts/check_image_migrations.sh \
#     --kratos ory-tidb-kratos:dev \
#     --keto   ory-tidb-keto:dev \
#     --hydra  ory-tidb-hydra:dev
#
# In CI, pass the just-pushed digest:
#   sh scripts/check_image_migrations.sh \
#     --kratos ghcr.io/org/ory-tidb-kratos@sha256:abc...
#
# Requires: docker
#
# Run from the repo root or from infra/vendored/ory-tidb/.

set -eu

TIDB_IMAGE="pingcap/tidb:v8.5.2"
RUN_ID="${RUN_ID:-$$}"
TIDB_CONTAINER="ory-tidb-mig-${RUN_ID}"
TIDB_NETWORK="ory-tidb-mig-net-${RUN_ID}"

DEFAULT_KRATOS="ghcr.io/jaakkonen/ory-tidb-kratos:latest"
DEFAULT_KETO="ghcr.io/jaakkonen/ory-tidb-keto:latest"
DEFAULT_HYDRA="ghcr.io/jaakkonen/ory-tidb-hydra:latest"

KRATOS_IMAGE="$DEFAULT_KRATOS"
KETO_IMAGE="$DEFAULT_KETO"
HYDRA_IMAGE="$DEFAULT_HYDRA"
ONLY=""

# ── arg parsing ───────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --kratos) KRATOS_IMAGE="$2"; shift 2 ;;
    --keto)   KETO_IMAGE="$2";   shift 2 ;;
    --hydra)  HYDRA_IMAGE="$2";  shift 2 ;;
    --only)   ONLY="$2";         shift 2 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# ── helpers ───────────────────────────────────────────────────────────────────

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

cleanup() {
  log "Cleaning up containers and network..."
  docker rm -f "${TIDB_CONTAINER}" >/dev/null 2>&1 || true
  docker network rm "${TIDB_NETWORK}" >/dev/null 2>&1 || true
}

start_tidb() {
  cleanup
  log "Creating docker network ${TIDB_NETWORK}..."
  docker network create "${TIDB_NETWORK}" >/dev/null
  log "Starting TiDB container (${TIDB_IMAGE}, unistore mode)..."
  docker run -d \
    --name "${TIDB_CONTAINER}" \
    --network "${TIDB_NETWORK}" \
    "${TIDB_IMAGE}" \
    --store=unistore --path="" -L error >/dev/null

  log "Waiting for TiDB to be ready..."
  i=0
  while [ $i -lt 60 ]; do
    if docker run --rm \
        --network "${TIDB_NETWORK}" \
        mysql:8.0 \
        mysql -h "${TIDB_CONTAINER}" -P 4000 -u root --protocol=TCP \
        -e "SELECT 1" >/dev/null 2>&1; then
      log "TiDB is ready."
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  log "ERROR: TiDB did not become ready in 120s."
  return 1
}

create_db() {
  db="$1"
  docker run --rm \
    --network "${TIDB_NETWORK}" \
    mysql:8.0 \
    mysql -h "${TIDB_CONTAINER}" -P 4000 -u root --protocol=TCP \
    -e "CREATE DATABASE IF NOT EXISTS \`${db}\`;" >/dev/null 2>&1
}

# run_migrate LABEL IMAGE DB CMD...
# Runs CMD... inside IMAGE on the TiDB network, with DSN env var set.
# CMD is the full migrate command for the binary — differs per component.
run_migrate() {
  label="$1"
  image="$2"
  db="$3"
  shift 3  # remaining args are the command to run inside the container

  log "Testing ${label} migration (image: ${image})..."
  create_db "$db"

  # URL-style DSN — FinalizeDSN inside the binary converts it to the native
  # tcp() format required by go-sql-driver/mysql.
  dsn="tidb://root@${TIDB_CONTAINER}:4000/${db}"

  set +e
  output=$(docker run --rm \
    --network "${TIDB_NETWORK}" \
    -e "DSN=${dsn}" \
    "${image}" \
    "$@" 2>&1)
  rc=$?
  set -e

  if [ $rc -eq 0 ]; then
    pass "$label"
  else
    fail "$label (exit $rc)"
    printf '%s\n' "$output" | head -20 | sed 's/^/    /'
    return 1
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────

trap cleanup EXIT
start_tidb

total_errors=0

run_kratos() { run_migrate "Kratos" "$KRATOS_IMAGE" "kratos" migrate sql up -e --yes || total_errors=$((total_errors + 1)); }
run_hydra()  { run_migrate "Hydra"  "$HYDRA_IMAGE"  "hydra"  migrate sql up -e --yes || total_errors=$((total_errors + 1)); }

# Keto uses a config-file-based driver — DSN env alone is not enough; it
# requires at least one config file to exist. Write a minimal one to a tmpfile
# and mount it into the container via -v.
run_keto() {
  label="Keto"
  image="$KETO_IMAGE"
  db="keto"

  log "Testing ${label} migration (image: ${image})..."
  create_db "$db"

  dsn="tidb://root@${TIDB_CONTAINER}:4000/${db}"

  cfg=$(mktemp)
  printf 'dsn: "%s"\nnamespaces: []\n' "${dsn}" > "${cfg}"
  chmod 644 "${cfg}"

  set +e
  output=$(docker run --rm \
    --network "${TIDB_NETWORK}" \
    -v "${cfg}:/tmp/keto.yml:ro" \
    "${image}" \
    migrate up --yes -c /tmp/keto.yml 2>&1)
  rc=$?
  set -e

  rm -f "${cfg}"

  if [ $rc -eq 0 ]; then
    pass "$label"
  else
    fail "$label (exit $rc)"
    printf '%s\n' "$output" | head -20 | sed 's/^/    /'
    total_errors=$((total_errors + 1))
  fi
}

case "${ONLY:-all}" in
  kratos) run_kratos ;;
  keto)   run_keto   ;;
  hydra)  run_hydra  ;;
  all)    run_kratos; run_keto; run_hydra ;;
  *)      printf 'Unknown component: %s\n' "$ONLY" >&2; exit 1 ;;
esac

if [ "$total_errors" -eq 0 ]; then
  log "All image migration checks passed."
else
  log "FAILED: $total_errors component(s) failed migration check."
  exit 1
fi
