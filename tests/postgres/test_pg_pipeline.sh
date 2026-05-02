#!/usr/bin/env bash
# Test harness: exercises the exact pg_dump|restic backup and pg_restore pipeline
# from lib/generators.sh Postgres branch, against a local restic repo (skipping rclone).
set -euo pipefail

TESTDIR=/tmp/backupd-test
PGSOCK=$TESTDIR/sock
PG_HOST=$PGSOCK   # use socket directory as "host" (libpq treats path starting with / as socket dir)
PG_PORT=55433
PG_USER=postgres
RESTIC=$TESTDIR/bin/restic
REPO=$TESTDIR/restic-repo
RESTIC_PASSWORD="testpass-12345-verylongpassphrase"
HOSTNAME_TEST="testhost"

echo "===== Phase 1: Initialize restic repo ====="
rm -rf "$REPO"
RESTIC_PASSWORD="$RESTIC_PASSWORD" "$RESTIC" init --repo "$REPO" 2>&1 | tail -3
echo

echo "===== Phase 2: List user DBs (mirrors generator query) ====="
DBS="$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -tAc \
  "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname NOT IN ('postgres')" 2>&1)"
echo "Discovered DBs: $DBS"
echo

echo "===== Phase 3: Backup cluster globals ====="
if pg_dumpall -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" --globals-only 2>/dev/null | \
  RESTIC_PASSWORD="$RESTIC_PASSWORD" "$RESTIC" -r "$REPO" backup \
    --retry-lock 2m \
    --stdin --stdin-filename "_globals.sql" \
    --tag database --tag "engine:postgres" --tag "db:_globals" \
    --host "$HOSTNAME_TEST" 2>&1 | tail -5; then
  echo "  OK: _globals"
else
  echo "  FAILED: _globals"
  exit 1
fi
echo

echo "===== Phase 4: Backup each user DB ====="
for db in $DBS; do
  echo "  Backing up: $db"
  if pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
      --format=custom --no-owner --no-privileges -d "$db" 2>/dev/null | \
    RESTIC_PASSWORD="$RESTIC_PASSWORD" "$RESTIC" -r "$REPO" backup \
      --retry-lock 2m \
      --stdin --stdin-filename "${db}.dump" \
      --tag database --tag "engine:postgres" --tag "db:${db}" \
      --host "$HOSTNAME_TEST" 2>&1 | tail -3; then
    echo "    OK: $db"
  else
    echo "    FAILED: $db"
    exit 1
  fi
done
echo

echo "===== Phase 5: Snapshots created ====="
RESTIC_PASSWORD="$RESTIC_PASSWORD" "$RESTIC" -r "$REPO" snapshots --json 2>/dev/null | \
  python3 -c "import sys,json; [print(s['short_id'], s['tags'], s['paths']) for s in json.load(sys.stdin)]"
echo

echo "===== Phase 6: Capture pre-restore counts, then DROP DBs ====="
SHOP_PRODUCTS_PRE=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d shop_app -tAc "SELECT count(*) FROM products")
SHOP_ORDERS_PRE=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d shop_app -tAc "SELECT count(*) FROM orders")
BLOG_POSTS_PRE=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d blog_app -tAc "SELECT count(*) FROM posts")
echo "Pre-restore: shop_app.products=$SHOP_PRODUCTS_PRE shop_app.orders=$SHOP_ORDERS_PRE blog_app.posts=$BLOG_POSTS_PRE"

psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c "DROP DATABASE shop_app" 2>&1 | tail -1
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c "DROP DATABASE blog_app" 2>&1 | tail -1
echo

echo "===== Phase 7: Restore each DB from latest snapshot ====="
for db in shop_app blog_app; do
  echo "  Restoring: $db"

  # Find the latest snapshot tagged for this db
  SNAP_ID=$(RESTIC_PASSWORD="$RESTIC_PASSWORD" "$RESTIC" -r "$REPO" snapshots --tag "db:${db}" --json --latest 1 2>/dev/null | \
    python3 -c "import sys,json; data=json.load(sys.stdin); print(data[0]['short_id']) if data else exit(1)")
  echo "    snapshot: $SNAP_ID"

  # Extract the dump from the snapshot
  TEMP_DUMP=$(mktemp --suffix=.dump)
  chmod 600 "$TEMP_DUMP"
  RESTIC_PASSWORD="$RESTIC_PASSWORD" "$RESTIC" -r "$REPO" dump "$SNAP_ID" "/${db}.dump" > "$TEMP_DUMP" 2>/dev/null
  echo "    extracted $(stat -c%s "$TEMP_DUMP") bytes"

  # Pre-create the DB
  psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c "CREATE DATABASE \"$db\"" 2>&1 | tail -1

  # pg_restore
  pg_restore -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
    --clean --if-exists --no-owner --no-privileges \
    -d "$db" "$TEMP_DUMP" 2>&1 | tail -3
  rm -f "$TEMP_DUMP"
  echo "    OK: $db"
done
echo

echo "===== Phase 8: Verify post-restore counts match ====="
SHOP_PRODUCTS_POST=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d shop_app -tAc "SELECT count(*) FROM products")
SHOP_ORDERS_POST=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d shop_app -tAc "SELECT count(*) FROM orders")
BLOG_POSTS_POST=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d blog_app -tAc "SELECT count(*) FROM posts")
echo "Post-restore: shop_app.products=$SHOP_PRODUCTS_POST shop_app.orders=$SHOP_ORDERS_POST blog_app.posts=$BLOG_POSTS_POST"

if [[ "$SHOP_PRODUCTS_PRE" == "$SHOP_PRODUCTS_POST" \
   && "$SHOP_ORDERS_PRE" == "$SHOP_ORDERS_POST" \
   && "$BLOG_POSTS_PRE" == "$BLOG_POSTS_POST" ]]; then
  echo
  echo "===== ✓ TEST PASSED — all row counts match ====="
  exit 0
else
  echo
  echo "===== ✗ TEST FAILED — counts differ ====="
  exit 1
fi
