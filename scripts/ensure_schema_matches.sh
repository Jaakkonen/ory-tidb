#!/usr/bin/env sh
# SPDX-License-Identifier: LicenseRef-Proprietary
# © CRACI Corporation Oy. All rights reserved.
#
# ensure_schema_matches.sh — run migrations against both MySQL 8.0 and TiDB,
# dump the resulting schemas, and assert that any differences are minimal
# (only known cosmetic TiDB annotations).
#
# Philosophy:
#   TiDB is wire-compatible with MySQL 8.0, which is Ory's primary target.
#   After applying all migrations the resulting schemas should be structurally
#   identical.  Known cosmetic differences (TiDB clustered-index hints, charset
#   collation order, AUTO_INCREMENT values, JSON/expression default syntax) are
#   normalised away before diffing so the comparison is meaningful.
#
#   If an unexpected diff appears it means either:
#     a) A new migration was not patched correctly for TiDB, or
#     b) A new normalisation rule needs to be added to this script.
#
# Usage:
#   sh scripts/ensure_schema_matches.sh [kratos|keto|hydra|all]
#
# Environment variables:
#   RUN_ID   — suffix for container/network names (default: $$).
#
# Requires: docker
#
# Exit codes:
#   0  — schemas match after normalisation
#   1  — unexpected schema differences found, or a migration failed
#
# Run from the repo root or from infra/vendored/ory-tidb/.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPONENT="${1:-all}"

TIDB_IMAGE="pingcap/tidb:v8.5.2"
MYSQL_IMAGE="mysql:8.0"

RUN_ID="${RUN_ID:-$$}"
TIDB_CONTAINER="ory-schema-tidb-${RUN_ID}"
MYSQL_CONTAINER="ory-schema-mysql-${RUN_ID}"
CLIENT_CONTAINER="ory-schema-client-${RUN_ID}"
NETWORK="ory-schema-net-${RUN_ID}"

KRATOS_DIR="${REPO_DIR}/kratos/persistence/sql/migrations/sql"
KETO_DIR="${REPO_DIR}/keto/internal/persistence/sql/migrations/sql"
KETO_NETWORKX_DIR="${REPO_DIR}/keto/oryx/networkx/migrations/sql"
HYDRA_DIR="${REPO_DIR}/hydra/persistence/sql/migrations"

# Use a stable path in CI (RUNNER_TEMP is set by GitHub Actions), otherwise mktemp.
if [ -n "${RUNNER_TEMP:-}" ]; then
  DUMP_DIR="${RUNNER_TEMP}/schema-dumps-${RUN_ID}"
  mkdir -p "$DUMP_DIR"
else
  DUMP_DIR="$(mktemp -d)"
fi

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

cleanup() {
  log "Cleaning up containers, network, and temp files..."
  docker rm -f "${TIDB_CONTAINER}"  >/dev/null 2>&1 || true
  docker rm -f "${MYSQL_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${CLIENT_CONTAINER}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK}"    >/dev/null 2>&1 || true
  rm -rf "${DUMP_DIR}"
}
trap cleanup EXIT

wait_for() {
  host="$1"; port="$2"; label="$3"
  log "Waiting for ${label} to be ready..."
  i=0
  while [ $i -lt 60 ]; do
    if docker exec "${CLIENT_CONTAINER}" \
        mysql -h "$host" -P "$port" -u root --protocol=TCP \
        -e "SELECT 1" >/dev/null 2>&1; then
      log "${label} is ready."
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  log "ERROR: ${label} did not become ready in 120s."
  return 1
}

# ── startup ──────────────────────────────────────────────────────────────────

log "Creating docker network ${NETWORK}..."
docker network create "${NETWORK}" >/dev/null

log "Starting TiDB container (${TIDB_IMAGE}, unistore)..."
docker run -d \
  --name "${TIDB_CONTAINER}" \
  --network "${NETWORK}" \
  "${TIDB_IMAGE}" \
  --store=unistore --path="" -L error >/dev/null

log "Starting MySQL 8 container (${MYSQL_IMAGE})..."
docker run -d \
  --name "${MYSQL_CONTAINER}" \
  --network "${NETWORK}" \
  -e MYSQL_ALLOW_EMPTY_PASSWORD=yes \
  "${MYSQL_IMAGE}" >/dev/null

log "Starting MySQL client sidecar..."
docker run -d \
  --name "${CLIENT_CONTAINER}" \
  --network "${NETWORK}" \
  --entrypoint sleep \
  "${MYSQL_IMAGE}" infinity >/dev/null

wait_for "${TIDB_CONTAINER}"  4000 "TiDB"
wait_for "${MYSQL_CONTAINER}" 3306 "MySQL"

# ── migration runner ──────────────────────────────────────────────────────────

create_db() {
  host="$1"; port="$2"; db="$3"
  docker exec "${CLIENT_CONTAINER}" \
    mysql -h "$host" -P "$port" -u root --protocol=TCP \
    -e "CREATE DATABASE IF NOT EXISTS \`${db}\`;" 2>/dev/null
}

# Select the migration file to apply for a given base+direction+dialect.
# tidb:  prefer .tidb.up.sql > "all" (.up.sql)
# mysql: prefer .mysql.up.sql > "all" (.up.sql)
select_migration_file() {
  dir="$1"; base="$2"; direction="$3"; dialect="$4"
  tidb_file="${dir}/${base}.tidb.${direction}.sql"
  mysql_file="${dir}/${base}.mysql.${direction}.sql"
  all_file="${dir}/${base}.${direction}.sql"
  autocommit_file="${dir}/${base}.autocommit.${direction}.sql"
  if [ "$dialect" = "tidb" ]; then
    if   [ -f "$tidb_file"       ]; then printf '%s' "$tidb_file"
    elif [ -f "$all_file"        ]; then printf '%s' "$all_file"
    elif [ -f "$autocommit_file" ]; then printf '%s' "$autocommit_file"
    fi
  else
    if   [ -f "$mysql_file"      ]; then printf '%s' "$mysql_file"
    elif [ -f "$all_file"        ]; then printf '%s' "$all_file"
    elif [ -f "$autocommit_file" ]; then printf '%s' "$autocommit_file"
    fi
  fi
}

run_migrations_on() {
  host="$1"; port="$2"; db="$3"; dir="$4"; label="$5"; dialect="$6"
  create_db "$host" "$port" "$db"

  bases=$(ls "${dir}"/*.up.sql 2>/dev/null \
    | sed 's|.*/||' \
    | sed 's/\.\(tidb\|mysql\|postgres\|cockroach\|sqlite3\|sqlite\|autocommit\)\(\.autocommit\)\?\.\(up\)\.sql$/.\3.sql/' \
    | sed 's/\.up\.sql$//' \
    | sort -u)

  count=0
  for base in $bases; do
    chosen=$(select_migration_file "$dir" "$base" "up" "$dialect")
    [ -z "$chosen" ] && continue
    [ ! -s "$chosen" ] && continue   # skip empty files
    output=$(docker exec -i "${CLIENT_CONTAINER}" \
      mysql -h "$host" -P "$port" -u root --protocol=TCP \
      "$db" < "$chosen" 2>&1) && rc=0 || rc=$?
    if [ $rc -ne 0 ]; then
      fail "${label}: $(basename "$chosen") — ${output}"
      return 1
    fi
    count=$((count + 1))
  done
  log "${label}: applied $count migrations."
}

# ── schema dump and normalisation ─────────────────────────────────────────────

# Dump and normalise the schema of a database into a canonical form suitable
# for diffing.  Each CREATE TABLE block is extracted and normalised independently,
# then blocks are sorted by table name so ordering differences don't matter.
#
# Normalisation removes known cosmetic differences between MySQL 8 and TiDB:
#   - TiDB clustered-index hint comments
#   - AUTO_INCREMENT counter values
#   - ROW_FORMAT=COMPACT (TiDB) vs omitted (MySQL)
#   - COLLATE= annotations (MySQL 8 uses 0900_ai_ci; TiDB uses utf8mb4_bin)
#   - Expression vs literal defaults (JSON_ARRAY() vs '[]', etc.)
#   - CHECK constraints (TiDB silently ignores multi-column CHECKs)
#   - FK constraint names (stripped; only referenced columns/tables compared)
#   - ON UPDATE RESTRICT (MySQL default, may be explicit on one side only)
#   - Trailing whitespace and trailing commas on last lines
dump_schema() {
  host="$1"; port="$2"; db="$3"; outfile="$4"

  docker exec "${CLIENT_CONTAINER}" \
    mysqldump -h "$host" -P "$port" -u root --protocol=TCP \
    --no-data --skip-comments --skip-add-drop-table \
    --skip-set-charset --skip-tz-utc \
    "$db" 2>/dev/null \
  | python3 - "$outfile" <<'PYEOF'
import sys, re

outfile = sys.argv[1]

raw = sys.stdin.read()

# ── per-line normalisations ──────────────────────────────────────────────────

def normalise_line(line):
    # 1. TiDB clustered-index and other /*T![...] ...*/ hints
    line = re.sub(r'/\*T!\[[^\]]*\][^/]*/\s*', '', line)
    # 2. AUTO_INCREMENT counter value
    line = re.sub(r' AUTO_INCREMENT=\d+', '', line)
    # 3. ROW_FORMAT=COMPACT
    line = re.sub(r' ROW_FORMAT=COMPACT', '', line)
    # 4. All COLLATE annotations (column and table level)
    line = re.sub(r' COLLATE[= ][^ ,);]+', '', line, flags=re.IGNORECASE)
    # 5. DEFAULT CHARSET normalise (strip version-specific suffix)
    line = re.sub(r'( DEFAULT CHARSET=utf8mb4)\b[^;]*', r'\1', line)
    # 6. Expression defaults ↔ literal defaults normalisation
    #    TiDB: DEFAULT (JSON_ARRAY())  MySQL: DEFAULT '[]'
    line = line.replace("DEFAULT '[]'", "DEFAULT (JSON_ARRAY())")
    line = line.replace("DEFAULT '{}' ", "DEFAULT (JSON_OBJECT())")
    line = line.replace("DEFAULT ''",   "DEFAULT (JSON_QUOTE(''))")
    # Normalise outer-paren variants MySQL 8 emits
    line = line.replace("DEFAULT (JSON_ARRAY())", "DEFAULT JSON_ARRAY()")
    line = line.replace("DEFAULT (JSON_OBJECT())", "DEFAULT JSON_OBJECT()")
    line = line.replace("DEFAULT (JSON_QUOTE(''))", "DEFAULT JSON_QUOTE('')")
    # 7. ON UPDATE RESTRICT (implicit default, may be explicit on one side)
    line = re.sub(r'\s+ON UPDATE RESTRICT', '', line)
    # 8. FK constraint names — strip name, keep only columns+references
    line = re.sub(r'CONSTRAINT `[^`]+` (FOREIGN KEY)', r'\1', line)
    # 9. Trailing whitespace and trailing comma
    line = line.rstrip().rstrip(',')
    return line

# ── split into CREATE TABLE blocks ───────────────────────────────────────────

# Split the dump into table blocks.  Each block starts at "CREATE TABLE" and
# ends at the closing ");" (ENGINE= line).
blocks = {}
current_table = None
current_lines = []

for raw_line in raw.splitlines():
    m = re.match(r"CREATE TABLE `([^`]+)`", raw_line)
    if m:
        current_table = m.group(1)
        current_lines = [raw_line]
        continue
    if current_table is not None:
        current_lines.append(raw_line)
        # Engine line ends the block
        if re.match(r'\) ENGINE=', raw_line.strip()):
            blocks[current_table] = current_lines[:]
            current_table = None
            current_lines = []

# ── normalise each block ─────────────────────────────────────────────────────

normalised = {}
for table, lines in blocks.items():
    norm = []
    for line in lines:
        n = normalise_line(line)
        # Drop CHECK constraints (TiDB silently ignores complex multi-column CHECKs)
        if re.search(r'\bCHECK\s*\(', n, re.IGNORECASE):
            continue
        # Drop blank lines
        if not n.strip():
            continue
        norm.append(n)
    # Sort the interior lines (between CREATE TABLE and ENGINE) so order
    # differences within a table don't matter.
    if len(norm) >= 2:
        header = norm[0]   # CREATE TABLE line
        footer = norm[-1]  # ENGINE= line
        interior = sorted(norm[1:-1])
        norm = [header] + interior + [footer]
    normalised[table] = norm

# ── output: tables sorted by name ────────────────────────────────────────────

with open(outfile, 'w') as f:
    for table in sorted(normalised.keys()):
        for line in normalised[table]:
            f.write(line + '\n')
        f.write('\n')
PYEOF
}

# ── schema comparison ─────────────────────────────────────────────────────────

compare_schemas() {
  label="$1"; mysql_dump="$2"; tidb_dump="$3"

  if diff -u "$mysql_dump" "$tidb_dump" > "${DUMP_DIR}/diff_${label}.txt" 2>&1; then
    pass "${label}: schemas are identical after normalisation"
    return 0
  else
    fail "${label}: unexpected schema differences found"
    printf '\n--- schema diff for %s (mysql vs tidb, after normalisation) ---\n' "$label"
    cat "${DUMP_DIR}/diff_${label}.txt"
    printf '--- end diff ---\n\n'
    return 1
  fi
}

# ── per-component ─────────────────────────────────────────────────────────────

check_component() {
  label="$1"; db="$2"; shift 2
  # remaining args: one or more migration dirs.
  # All dirs are applied to TiDB first (in order), then all to MySQL, so each
  # engine gets a clean independent database.

  log "=== ${label} ==="

  for dir in "$@"; do
    run_migrations_on "${TIDB_CONTAINER}"  4000 "$db" "$dir" "tidb:${label}"  tidb  || return 1
  done
  for dir in "$@"; do
    run_migrations_on "${MYSQL_CONTAINER}" 3306 "$db" "$dir" "mysql:${label}" mysql || return 1
  done

  dump_schema "${TIDB_CONTAINER}"  4000 "$db" "${DUMP_DIR}/${label}_tidb.sql"
  dump_schema "${MYSQL_CONTAINER}" 3306 "$db" "${DUMP_DIR}/${label}_mysql.sql"

  compare_schemas "$label" \
    "${DUMP_DIR}/${label}_mysql.sql" \
    "${DUMP_DIR}/${label}_tidb.sql"
}

# ── main ─────────────────────────────────────────────────────────────────────

total_errors=0

case "$COMPONENT" in
  kratos)
    check_component "kratos" "kratos" "$KRATOS_DIR" \
      || total_errors=$((total_errors + 1))
    ;;
  keto)
    check_component "keto" "keto" "$KETO_NETWORKX_DIR" "$KETO_DIR" \
      || total_errors=$((total_errors + 1))
    ;;
  hydra)
    check_component "hydra" "hydra" "$HYDRA_DIR" \
      || total_errors=$((total_errors + 1))
    ;;
  all)
    check_component "kratos" "kratos" "$KRATOS_DIR" \
      || total_errors=$((total_errors + 1))
    check_component "keto" "keto" "$KETO_NETWORKX_DIR" "$KETO_DIR" \
      || total_errors=$((total_errors + 1))
    check_component "hydra" "hydra" "$HYDRA_DIR" \
      || total_errors=$((total_errors + 1))
    ;;
  *)
    printf 'Usage: %s [kratos|keto|hydra|all]\n' "$0" >&2
    exit 1
    ;;
esac

if [ "$total_errors" -eq 0 ]; then
  log "All schema comparisons passed."
  exit 0
else
  log "FAILED: ${total_errors} component(s) have unexpected schema differences."
  exit 1
fi
