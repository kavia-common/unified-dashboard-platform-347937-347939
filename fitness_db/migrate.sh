#!/usr/bin/env sh
set -eu

# Simple migration runner for Postgres using psql.
# Expects standard libpq env vars:
#   DATABASE_URL (preferred) OR PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE
#
# NOTE: This repository did not provide DB env vars in fitness_db/.env yet.
# The orchestrator should configure DATABASE_URL (or equivalent) for the DB container.

MIGRATIONS_DIR="${MIGRATIONS_DIR:-./migrations}"

if [ ! -d "$MIGRATIONS_DIR" ]; then
  echo "Migrations directory not found: $MIGRATIONS_DIR" >&2
  exit 1
fi

# Determine how to connect:
# - Prefer DATABASE_URL if set
# - Else rely on PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE env vars supported by psql
PSQL_CONN_ARG=""
if [ "${DATABASE_URL:-}" != "" ]; then
  PSQL_CONN_ARG="${DATABASE_URL}"
fi

echo "Applying migrations from: $MIGRATIONS_DIR"

# Apply in lexical order: 001_*.sql, 002_*.sql, etc.
for f in $(ls -1 "$MIGRATIONS_DIR"/*.sql 2>/dev/null | sort); do
  echo "-> Applying $f"
  if [ "$PSQL_CONN_ARG" != "" ]; then
    psql "$PSQL_CONN_ARG" -v ON_ERROR_STOP=1 -f "$f"
  else
    psql -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "Migrations complete."
