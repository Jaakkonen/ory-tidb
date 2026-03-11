#!/usr/bin/env sh
# SPDX-License-Identifier: LicenseRef-Proprietary
# © CRACI Corporation Oy. All rights reserved.
#
# check_new_migrations.sh — detect upstream migrations that have no .tidb.sql counterpart.
#
# For each Ory component, scans the migration directory for .mysql.up.sql files
# that do not have a corresponding .tidb.up.sql file.  Any such file means a
# new upstream migration was added without a TiDB variant — the fork branch needs
# to be updated.
#
# Usage:
#   sh scripts/check_new_migrations.sh [kratos|keto|hydra|all]
#
# Exit codes:
#   0  — all mysql migrations have a tidb counterpart (or are intentionally absent)
#   1  — one or more mysql migrations are missing a .tidb.up.sql file
#
# Run from the repo root or from infra/vendored/ory-tidb/.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPONENT="${1:-all}"

KRATOS_DIR="${REPO_DIR}/kratos/persistence/sql/migrations/sql"
KETO_DIR="${REPO_DIR}/keto/internal/persistence/sql/migrations/sql"
KETO_NETWORKX_DIR="${REPO_DIR}/keto/oryx/networkx/migrations/sql"
HYDRA_DIR="${REPO_DIR}/hydra/persistence/sql/migrations"

# ── helpers ──────────────────────────────────────────────────────────────────

pass()  { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn()  { printf '  \033[33mMISS\033[0m %s\n' "$*"; }
info()  { printf '[check] %s\n' "$*"; }

# Check one migration directory.
# Prints a warning for every .mysql.up.sql without a .tidb.up.sql.
# Returns the count of missing files (non-zero = problem).
check_dir() {
  dir="$1"
  label="$2"

  if [ ! -d "$dir" ]; then
    printf '[check] WARNING: directory not found: %s\n' "$dir" >&2
    return 0
  fi

  info "Checking ${label} (${dir})..."
  missing=0

  for mysql_file in "${dir}"/*.mysql.up.sql; do
    [ -e "$mysql_file" ] || continue
    base="$(basename "$mysql_file" .mysql.up.sql)"
    tidb_file="${dir}/${base}.tidb.up.sql"
    if [ ! -f "$tidb_file" ]; then
      warn "${label}: missing ${base}.tidb.up.sql  (has .mysql.up.sql)"
      missing=$((missing + 1))
    else
      pass "${base}.tidb.up.sql"
    fi
  done

  if [ "$missing" -eq 0 ]; then
    info "${label}: all mysql migrations have a tidb counterpart."
  else
    info "${label}: ${missing} migration(s) missing a .tidb.up.sql file."
  fi

  return "$missing"
}

# ── main ─────────────────────────────────────────────────────────────────────

total_missing=0

case "$COMPONENT" in
  kratos)
    check_dir "$KRATOS_DIR" "kratos" || total_missing=$((total_missing + $?))
    ;;
  keto)
    check_dir "$KETO_NETWORKX_DIR" "keto/networkx" || total_missing=$((total_missing + $?))
    check_dir "$KETO_DIR"          "keto"          || total_missing=$((total_missing + $?))
    ;;
  hydra)
    check_dir "$HYDRA_DIR" "hydra" || total_missing=$((total_missing + $?))
    ;;
  all)
    check_dir "$KRATOS_DIR"        "kratos"        || total_missing=$((total_missing + $?))
    check_dir "$KETO_NETWORKX_DIR" "keto/networkx" || total_missing=$((total_missing + $?))
    check_dir "$KETO_DIR"          "keto"          || total_missing=$((total_missing + $?))
    check_dir "$HYDRA_DIR"         "hydra"         || total_missing=$((total_missing + $?))
    ;;
  *)
    printf 'Usage: %s [kratos|keto|hydra|all]\n' "$0" >&2
    exit 1
    ;;
esac

if [ "$total_missing" -eq 0 ]; then
  info "All mysql migrations have a .tidb.up.sql counterpart."
  exit 0
else
  info "FAILED: ${total_missing} migration(s) are missing a .tidb.up.sql file."
  info "Run scripts/gen_tidb_migrations.sh and fix any TiDB-incompatible DDL."
  exit 1
fi
