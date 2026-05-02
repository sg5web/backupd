#!/usr/bin/env bash
# End-to-end test: invoke the actual generator function with DB_ENGINE=postgres,
# inspect the generated script, then optionally run it.
set -euo pipefail

BACKUPD_REPO=/home/simon/work/other-projects/backupd
TESTDIR=/tmp/backupd-test
SCRIPTS_DIR=$TESTDIR/scripts
SECRETS_DIR=$TESTDIR/secrets
LOGS_DIR=$TESTDIR/logs
INSTALL_DIR=$BACKUPD_REPO

mkdir -p "$SCRIPTS_DIR" "$SECRETS_DIR" "$LOGS_DIR"
chmod 700 "$SECRETS_DIR"

# Source the relevant lib files
source "$BACKUPD_REPO/lib/logging.sh"
source "$BACKUPD_REPO/lib/generators.sh"

# Stub out helpers that the generator uses for status output (not relevant here)
print_success() { echo "[OK] $*"; }
print_error()   { echo "[ERROR] $*" >&2; }

echo "===== Generating db_backup.sh with DB_ENGINE=postgres ====="
generate_restic_db_backup_script \
  "$SECRETS_DIR" \
  "local-test" \
  "/tmp/backupd-test/rclone-target" \
  "$LOGS_DIR" \
  "30" \
  "postgres" \
  "/tmp/backupd-test/sock" \
  "55433"

echo
echo "===== Verifying placeholders were substituted ====="
if grep -q '%%' "$SCRIPTS_DIR/db_backup.sh"; then
  echo "FAIL: unsubstituted placeholders remain:"
  grep -n '%%' "$SCRIPTS_DIR/db_backup.sh"
  exit 1
fi
echo "OK: no %%placeholder%% remnants"

echo
echo "===== Verifying Postgres branch is present ====="
grep -n '"$DB_ENGINE" == "postgres"' "$SCRIPTS_DIR/db_backup.sh" | head -2
grep -n 'pg_dump\|pg_dumpall\|psql' "$SCRIPTS_DIR/db_backup.sh" | head -5

echo
echo "===== Verifying values were baked in ====="
grep -E '^DB_ENGINE=|^PG_HOST=|^PG_PORT=' "$SCRIPTS_DIR/db_backup.sh"

echo
echo "===== bash -n syntax check ====="
bash -n "$SCRIPTS_DIR/db_backup.sh" && echo "OK"

echo
echo "===== ✓ Generator output looks correct ====="
