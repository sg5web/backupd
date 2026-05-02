# PostgreSQL test harness

End-to-end tests for the PostgreSQL dump/restore pipeline introduced in
[#1](https://github.com/sg5web/backupd/issues/1).

## Prerequisites

- PostgreSQL 17 client+server (`pg_dump`, `pg_restore`, `psql`, `initdb`, `pg_ctl`)
- A `restic` binary (any recent version; `v0.18.0+` known good)
- `python3` for snapshot JSON parsing in the pipeline test
- ~50 MB free space in `/tmp`

## Setup — isolated Postgres cluster on a high port

These tests deliberately avoid touching any local production Postgres. They
spin up an isolated cluster on port `55433` rooted in `/tmp/backupd-test/pgdata`,
seed two sample databases, and run the dump+restore cycle against it.

```bash
TESTDIR=/tmp/backupd-test
PGDATA=$TESTDIR/pgdata
PGSOCK=$TESTDIR/sock
PGPORT=55433
mkdir -p "$PGDATA" "$PGSOCK"
chmod 700 "$PGDATA"

# Initialize cluster with trust auth (test-only)
/usr/lib/postgresql/17/bin/initdb -D "$PGDATA" \
  --auth-local=trust --auth-host=trust --username=postgres -E UTF8 -A trust

# Start
/usr/lib/postgresql/17/bin/pg_ctl -D "$PGDATA" -l "$TESTDIR/pg.log" \
  -o "-p $PGPORT -k $PGSOCK -h ''" start

# Sanity
psql -h "$PGSOCK" -p "$PGPORT" -U postgres -d postgres -c 'SELECT version()'
```

Seed sample data:

```bash
PG="psql -h $PGSOCK -p $PGPORT -U postgres"
$PG -d postgres -c "CREATE DATABASE shop_app"
$PG -d postgres -c "CREATE DATABASE blog_app"

$PG -d shop_app <<'SQL'
CREATE TABLE products (id serial PRIMARY KEY, sku text NOT NULL UNIQUE, name text, price numeric);
INSERT INTO products (sku, name, price)
  SELECT 'SKU-' || i, 'Product ' || i, (random()*100)::numeric(10,2)
  FROM generate_series(1, 50) i;
CREATE TABLE orders (id serial PRIMARY KEY, product_id int REFERENCES products(id), qty int, created_at timestamptz DEFAULT now());
INSERT INTO orders (product_id, qty)
  SELECT (random()*49)::int + 1, (random()*5)::int + 1 FROM generate_series(1, 200);
SQL

$PG -d blog_app <<'SQL'
CREATE TABLE posts (id serial PRIMARY KEY, title text, body text, published bool DEFAULT true);
INSERT INTO posts (title, body)
  SELECT 'Post ' || i, 'Body for post ' || i || ' ' || md5(random()::text)
  FROM generate_series(1, 25) i;
SQL
```

Get a restic binary (no system install needed):

```bash
mkdir -p /tmp/backupd-test/bin && cd /tmp/backupd-test/bin
curl -sL https://github.com/restic/restic/releases/download/v0.18.0/restic_0.18.0_linux_amd64.bz2 -o restic.bz2
bunzip2 restic.bz2 && chmod +x restic
```

## Tests

### `test_pg_pipeline.sh` — round-trip pipeline

Exercises the exact `pg_dump | restic backup --stdin` and `restic dump | pg_restore`
commands the generator emits, against a local restic repo (skipping rclone).

```bash
bash tests/postgres/test_pg_pipeline.sh
```

Expected: `✓ TEST PASSED — all row counts match`. Verifies:

- Cluster globals dumped via `pg_dumpall --globals-only`
- Per-DB dumps via `pg_dump --format=custom --no-owner --no-privileges`
- Snapshots tagged `database`, `engine:postgres`, `db:NAME`
- After dropping both DBs, restore via `pg_restore --clean --if-exists --no-owner --no-privileges`
- Row counts identical pre- and post-restore (50 products + 200 orders + 25 posts)

### `test_generator.sh` — generator output inspection

Calls `generate_restic_db_backup_script` from `lib/generators.sh` with `DB_ENGINE=postgres`
and verifies the resulting runtime script.

```bash
bash tests/postgres/test_generator.sh
```

Expected: `✓ Generator output looks correct`. Verifies:

- All `%%PLACEHOLDER%%` markers are substituted
- The Postgres branch (`if [[ "$DB_ENGINE" == "postgres" ]]`) is emitted
- `pg_dump`, `pg_dumpall`, `psql` commands appear
- `DB_ENGINE`, `PG_HOST`, `PG_PORT` are baked in correctly
- `bash -n` passes on the generated script

## Teardown

```bash
/usr/lib/postgresql/17/bin/pg_ctl -D /tmp/backupd-test/pgdata stop -m fast
rm -rf /tmp/backupd-test
```
