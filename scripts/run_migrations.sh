#!/usr/bin/env sh
# SPDX-License-Identifier: LicenseRef-Proprietary
# © CRACI Corporation Oy. All rights reserved.
#
# run_migrations.sh — apply Ory TiDB migrations against a live TiDB instance
# (unistore mode) and report pass/fail per migration file.
#
# Migration selection mirrors the Ory popx sortAndFilter logic:
#   - For each version, prefer the .tidb.up.sql file if it exists.
#   - Otherwise fall back to the "all" dialect file (no dialect suffix).
#   - Files for other dialects (mysql, postgres, cockroach, sqlite*, autocommit)
#     are ignored.
#
# Usage:
#   sh scripts/run_migrations.sh [kratos|keto|hydra|all]
#
# Environment variables:
#   RUN_ID   — suffix for container/network names (default: $$).
#              Set to a unique value when running multiple instances in parallel.
#
# Requires: docker
#
# Run from the repo root or from infra/vendored/ory-tidb/.

set -eu

TIDB_IMAGE="pingcap/tidb:v8.5.2"
MYSQL_IMAGE="mysql:8.0"
RUN_ID="${RUN_ID:-$$}"
TIDB_CONTAINER="ory-tidb-test-${RUN_ID}"
MYSQL_CONTAINER="ory-tidb-mysql-client-${RUN_ID}"
TIDB_NETWORK="ory-tidb-test-net-${RUN_ID}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPONENT="${1:-all}"

KRATOS_DIR="${REPO_DIR}/kratos/persistence/sql/migrations/sql"
KETO_NETWORKX_DIR="${REPO_DIR}/keto/oryx/networkx/migrations/sql"
KETO_DIR="${REPO_DIR}/keto/internal/persistence/sql/migrations/sql"
HYDRA_DIR="${REPO_DIR}/hydra/persistence/sql/migrations"

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

wait_for_tidb() {
  log "Waiting for TiDB to be ready..."
  i=0
  while [ $i -lt 60 ]; do
    if docker exec "${MYSQL_CONTAINER}" \
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

cleanup() {
  log "Cleaning up containers and network..."
  docker rm -f "${TIDB_CONTAINER}"  >/dev/null 2>&1 || true
  docker rm -f "${MYSQL_CONTAINER}" >/dev/null 2>&1 || true
  docker network rm "${TIDB_NETWORK}" >/dev/null 2>&1 || true
}

restart_tidb() {
  log "TiDB container crashed — restarting..."
  docker rm -f "${TIDB_CONTAINER}" >/dev/null 2>&1 || true
  docker run -d \
    --name "${TIDB_CONTAINER}" \
    --network "${TIDB_NETWORK}" \
    "${TIDB_IMAGE}" \
    --store=unistore --path="" -L error >/dev/null
  wait_for_tidb
}

ensure_tidb_running() {
  if ! docker inspect --format='{{.State.Running}}' "${TIDB_CONTAINER}" 2>/dev/null \
       | grep -q true; then
    restart_tidb
  fi
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
  log "Starting MySQL client sidecar (${MYSQL_IMAGE})..."
  docker run -d \
    --name "${MYSQL_CONTAINER}" \
    --network "${TIDB_NETWORK}" \
    --entrypoint sleep \
    "${MYSQL_IMAGE}" infinity >/dev/null
  wait_for_tidb
}

create_db() {
  db="$1"
  docker exec "${MYSQL_CONTAINER}" \
    mysql -h "${TIDB_CONTAINER}" -P 4000 -u root --protocol=TCP \
    -e "CREATE DATABASE IF NOT EXISTS \`${db}\`;" 2>/dev/null
}

run_migration() {
  db="$1"; file="$2"
  name="$(basename "$file")"
  if [ ! -s "$file" ]; then
    pass "$name (empty, skipped)"
    return 0
  fi
  ensure_tidb_running
  attempts=0
  while [ $attempts -lt 3 ]; do
    output=$(docker exec -i "${MYSQL_CONTAINER}" \
      mysql -h "${TIDB_CONTAINER}" -P 4000 -u root --protocol=TCP \
      "${db}" < "$file" 2>&1) && rc=0 || rc=$?
    if [ $rc -eq 0 ]; then
      if [ $attempts -gt 0 ]; then
        pass "$name (after TiDB restart)"
      else
        pass "$name"
      fi
      return 0
    fi
    tidb_running=$(docker inspect --format='{{.State.Running}}' "${TIDB_CONTAINER}" \
      2>/dev/null || echo "false")
    if [ "$tidb_running" != "true" ] || \
       printf '%s' "$output" | grep -q "2013\|Lost connection\|Can't connect\|OCI runtime\|nsexec"; then
      attempts=$((attempts + 1))
      log "TiDB crashed during $name (attempt $attempts/3), restarting..."
      restart_tidb
      continue
    fi
    break
  done
  fail "$name"
  printf '%s\n' "$output" | head -5 | sed 's/^/    /'
  return 1
}

select_migration_file() {
  dir="$1"; base="$2"; direction="$3"
  tidb_file="${dir}/${base}.tidb.${direction}.sql"
  all_file="${dir}/${base}.${direction}.sql"
  autocommit_file="${dir}/${base}.autocommit.${direction}.sql"
  if   [ -f "$tidb_file"       ]; then printf '%s' "$tidb_file"
  elif [ -f "$all_file"        ]; then printf '%s' "$all_file"
  elif [ -f "$autocommit_file" ]; then printf '%s' "$autocommit_file"
  fi
}

run_migrations() {
  dir="$1"; db="$2"; label="$3"
  log "Running ${label} migrations against database '${db}'..."
  create_db "$db"
  bases=$(ls "${dir}"/*.up.sql 2>/dev/null \
    | sed 's|.*/||' \
    | sed 's/\.\(tidb\|mysql\|postgres\|cockroach\|sqlite3\|sqlite\|autocommit\)\(\.autocommit\)\?\.\(up\)\.sql$/.\3.sql/' \
    | sed 's/\.up\.sql$//' \
    | sort -u)
  count=0
  for base in $bases; do
    chosen=$(select_migration_file "$dir" "$base" "up")
    [ -z "$chosen" ] && continue
    if ! run_migration "$db" "$chosen"; then
      log "${label}: aborted after $((count + 1)) migrations."
      return 1
    fi
    count=$((count + 1))
  done
  log "${label}: all $count migrations passed."
  return 0
}

# ── main ─────────────────────────────────────────────────────────────────────

trap cleanup EXIT
start_tidb
total_errors=0

case "$COMPONENT" in
  kratos)
    run_migrations "$KRATOS_DIR"        "kratos" "Kratos"        || total_errors=$((total_errors + $?))
    ;;
  keto)
    run_migrations "$KETO_NETWORKX_DIR" "keto"   "Keto/networkx" || total_errors=$((total_errors + $?))
    run_migrations "$KETO_DIR"          "keto"   "Keto"          || total_errors=$((total_errors + $?))
    ;;
  hydra)
    run_migrations "$HYDRA_DIR"         "hydra"  "Hydra"         || total_errors=$((total_errors + $?))
    ;;
  all)
    run_migrations "$KRATOS_DIR"        "kratos" "Kratos"        || total_errors=$((total_errors + $?))
    run_migrations "$KETO_NETWORKX_DIR" "keto"   "Keto/networkx" || total_errors=$((total_errors + $?))
    run_migrations "$KETO_DIR"          "keto"   "Keto"          || total_errors=$((total_errors + $?))
    run_migrations "$HYDRA_DIR"         "hydra"  "Hydra"         || total_errors=$((total_errors + $?))
    ;;
  *)
    printf 'Usage: %s [kratos|keto|hydra|all]\n' "$0" >&2
    exit 1
    ;;
esac

if [ "$total_errors" -eq 0 ]; then
  log "All migrations passed."
else
  log "FAILED: $total_errors migration(s) failed."
  exit 1
fi
