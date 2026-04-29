#!/usr/bin/env bash
# ============================================================
# Apply AIA migrations to local PostgreSQL test database
# Each migration is wrapped in a transaction to prevent partial applies.
# Usage: ./scripts/apply-migrations.sh
# ============================================================

set -euo pipefail

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-aia_test}"
DB_USER="${DB_USER:-aia_user}"
PGPASSWORD="${PGPASSWORD:-aia_pass}"
export PGPASSWORD

MIGRATIONS_DIR="supabase/migrations"
PASS_COUNT=0
FAIL_COUNT=0
FAILED_FILES=()

echo "============================================"
echo "  AIA Migration Runner"
echo "  Target: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "============================================"
echo ""

# Check connection
if ! pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" > /dev/null 2>&1; then
  echo "❌ Cannot connect to database. Is PostgreSQL running?"
  exit 1
fi

echo "✅ Database connection verified"
echo ""

# Apply each migration in order, wrapped in a transaction
for migration in $(ls "$MIGRATIONS_DIR"/*.sql | sort); do
  filename=$(basename "$migration")
  echo -n "  Applying $filename ... "

  # Wrap in transaction: if any statement fails, the whole migration rolls back
  if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 --single-transaction -f "$migration" > /dev/null 2>&1; then
    echo "✅"
    ((PASS_COUNT++))
  else
    echo "❌ FAILED"
    ((FAIL_COUNT++))
    FAILED_FILES+=("$filename")
    # Re-run to capture actual error
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
      -v ON_ERROR_STOP=1 --single-transaction -f "$migration" 2>&1 | grep -i 'error:' | head -3
    echo ""
  fi
done

echo ""
echo "============================================"
echo "  Migration Report"
echo "============================================"
echo "  Applied: $PASS_COUNT"
echo "  Failed:  $FAIL_COUNT"

if [ ${#FAILED_FILES[@]} -gt 0 ]; then
  echo ""
  echo "  Failed files:"
  for f in "${FAILED_FILES[@]}"; do
    echo "    - $f"
  done
fi

echo ""

# Schema inventory
echo "  Schema Inventory:"
echo -n "    Tables: "
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';"

echo -n "    Functions: "
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -tAc "SELECT count(DISTINCT routine_name) FROM information_schema.routines WHERE routine_schema = 'public';"

echo -n "    RLS Policies: "
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -tAc "SELECT count(*) FROM pg_policies WHERE schemaname = 'public';"

echo -n "    Enums: "
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -tAc "SELECT count(*) FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid WHERE n.nspname = 'public' AND t.typtype = 'e';"

echo ""

if [ $FAIL_COUNT -eq 0 ]; then
  echo "✅ ALL MIGRATIONS APPLIED SUCCESSFULLY"
else
  echo "❌ SOME MIGRATIONS FAILED — fix and re-run"
  exit 1
fi
