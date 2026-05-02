# Multi-engine support — design + handoff plan

> **Audience:** any agent picking up the multi-engine work cold.
> **Context:** this fork already has single-engine PostgreSQL support landed on
> `feature/postgres-support`. This doc covers the next step — letting one
> backupd install back up MySQL/MariaDB **and** PostgreSQL on the same host.
> **Tracking issues:** [#1](https://github.com/sg5web/backupd/issues/1) (Postgres support, single-engine — done), [#2](https://github.com/sg5web/backupd/issues/2) (multi-engine — this work).

## TL;DR

- **Branch to work on:** `feature/multi-engine` (already created, currently identical to `feature/postgres-support` + this doc)
- **Recommended design:** treat each DB engine as a separate **job** in the existing v3.1 multi-job system. The `default` job stays MySQL/MariaDB; create a new `postgres` job alongside.
- **Why jobs:** v3.1 already built ~70% of the machinery (`lib/jobs.sh`, job-aware timers in `lib/scheduler.sh`, migration code). The missing pieces are the user-facing `backupd job ...` CLI commands, the setup wizard scoped to a job, and a one-line lock-file fix.
- **Estimated scope:** ~450 lines across ~6 files. See "Implementation plan" below for file-by-file detail.
- **Don't:** invent parallel `DO_DATABASE_MYSQL` / `DO_DATABASE_POSTGRES` flags — that's the path the original issue #2 described, but it competes with the existing jobs system.

---

## Current state of this fork

### Branches

| Branch | Status | Description |
|---|---|---|
| `main` | upstream-tracking | mirrors `wnstify/backupd:main` (currently `v3.2.4`) |
| `feature/postgres-support` | landed (3 commits, pushed) | single-engine PostgreSQL support |
| `feature/multi-engine` | empty (was rebased on `postgres-support`; this doc is the only delta) | target for this work |

### Commits already on `feature/postgres-support` (inherited by `feature/multi-engine`)

1. `271ebcf` — *Add PostgreSQL support alongside MySQL/MariaDB*
2. `e13a17e` — *Add PostgreSQL test harness under tests/postgres/* (README only — `.gitignore` ate the `.sh` files)
3. `da0b66f` — *Add executable test scripts (gitignore was excluding test_*.sh)* — fixed the gitignore + added the actual test scripts

### What single-engine support already does

- `tenants.config["DB_ENGINE"]` in `$CONFIG_FILE` chooses `mysql` | `mariadb` | `postgres` at setup time (default `mysql` for back-compat)
- `PG_HOST` / `PG_PORT` config keys for Postgres connection
- Generator branches on `DB_ENGINE` inside the runtime `db_backup.sh`:
  - **mysql/mariadb:** existing `mysqldump` flow, snapshots tagged `engine:mysql`
  - **postgres:** `pg_dumpall --globals-only` once + `pg_dump --format=custom` per DB, snapshots tagged `engine:postgres`
- Auth via `PGPASSFILE` (mode 0600 temp file, exported, cleaned up) — same secrecy posture as MySQL `--defaults-extra-file`
- Restore wizard reads the `engine:*` snapshot tag and dispatches to the right import path (`mysql < dump.sql` or `pg_restore --clean --if-exists --no-owner --no-privileges`)
- `inline_restore_database` in `lib/restore.sh` mirrors the same split, reading config via `get_config_value` with `mysql` as fallback for older configs
- **Tested:** see `tests/postgres/` — round-trip backup+restore against an isolated Postgres 17 cluster, 50+200+25 row counts match exactly pre/post

### What single-engine support does NOT do

- A single backupd install can only be configured for ONE engine at a time. The setup wizard asks "which engine?" if both clients are detected.
- For hosts running both MySQL/MariaDB **and** Postgres (e.g. a server hosting both a Laravel app and a Python service), single-engine support is insufficient. → That's the multi-engine work.

---

## Architecture discovery (read first!)

The original design in issue #2 was "add `DO_DATABASE_MYSQL` / `DO_DATABASE_POSTGRES` flags to one job, generate two scripts, two timers." Then I read the code and found this:

### v3.1 already has a multi-job system

Look at `lib/jobs.sh` (1113 lines). It implements:

- Job CRUD: `create_job`, `delete_job`, `clone_job`, `list_jobs`, `_job_status_json`, `_job_status_text`
- Per-job structure: `/etc/backupd/jobs/{job_name}/{job.conf, scripts/}`
- Job naming validation: alphanumeric+dash+underscore, 2-32 chars, reserved names blocked
- Default job is `default`; protected from deletion
- Each `job.conf` carries: `JOB_NAME`, `JOB_ENABLED`, `DO_DATABASE`, `DO_FILES`, `WEB_PATH_PATTERN`, `WEBROOT_SUBDIR`, `RCLONE_REMOTE`, `RCLONE_DB_PATH`, `RCLONE_FILES_PATH`, `RETENTION_DAYS`, `SCHEDULE_DB`, `SCHEDULE_FILES`

### Job-aware systemd already works

`lib/scheduler.sh:312-340` (`scheduler_disable`):

```bash
if [[ "$job_name" == "default" ]]; then
  timer_name="backupd-${backup_type}.timer"
  service_name="backupd-${backup_type}.service"
else
  timer_name="backupd-${job_name}-${backup_type}.timer"     # ← this line
  service_name="backupd-${job_name}-${backup_type}.service"
fi
```

So a `postgres` job would automatically get `backupd-postgres-db.timer`. No collision with the default job's `backupd-db.timer`.

### Migration of legacy single-config exists

`lib/migration.sh` reads the old global `$CONFIG_FILE`, packages it as `/etc/backupd/jobs/default/job.conf`, and creates a `MIGRATION_MARKER`. Symlinks `db_backup.sh`, `files_backup.sh`, etc. from the global `scripts/` dir into the default job's scripts dir. Has a `rollback_migration` function too.

### What's missing

This is the actual scope of issue #2:

1. **`backupd job ...` CLI command is documented in help (`backupd.sh:272`) but not wired up.** No dispatch case in `parse_arguments`. Help output:
   ```
   job {list|create|delete|...} Manage backup jobs (v3.1)
   ```
2. **Setup wizard always writes to the global config + global scripts dir.** It can't currently produce a per-job config. `lib/setup.sh:399 save_config "RCLONE_REMOTE" "$RCLONE_REMOTE"` etc. write to `$CONFIG_FILE`, not to a job's `job.conf`.
3. **`generate_all_scripts`** writes to global `$SCRIPTS_DIR`. To support per-job, it needs a `job_name` (or a `target_scripts_dir`) parameter.
4. **Pre-existing bug:** generated `db_backup.sh` hardcodes `LOCK_FILE="/var/lock/backupd-db.lock"` regardless of job. Two jobs would silently serialize via that lock. Visible in `lib/generators.sh` at the line that emits `LOCK_FILE="/var/lock/backupd-db.lock"` — needs to become `LOCK_FILE="/var/lock/backupd-${JOB_NAME}-db.lock"` (when `JOB_NAME != default`) or just always namespaced.
5. **Per-job secrets dir.** Currently all secrets land in the global `$SECRETS_DIR`. For separate jobs with separate credentials (e.g. mysql user/pass for default job, postgres user/pass for postgres job), each job needs its own secrets dir. Convention: `/etc/backupd/jobs/{job_name}/secrets/` (mode 700).

---

## Recommended design

### User flow

```bash
# Existing install — default job is MySQL (already configured)
backupd setup        # → produces default job (mysql) — current behavior, unchanged

# Add a Postgres job alongside
backupd job create postgres
backupd job configure postgres
  → wizard scoped to this job: pick DB_ENGINE=postgres,
    collect PG host/port/user/password,
    collect rclone remote + path,
    set retention,
    set schedule
  → writes /etc/backupd/jobs/postgres/job.conf
  → writes /etc/backupd/jobs/postgres/secrets/.c1, .c2, .c3
  → generates /etc/backupd/jobs/postgres/scripts/db_backup.sh (Postgres branch)
  → creates backupd-postgres-db.timer + .service

# Default job (MySQL) keeps running on its existing schedule
# New backupd-postgres-db.timer fires independently
# Lock files: /var/lock/backupd-default-db.lock and /var/lock/backupd-postgres-db.lock
```

### Per-job state layout (post-implementation)

```
/etc/backupd/
  jobs/
    default/
      job.conf            # MySQL/MariaDB config
      secrets/            # .c1..c9 — restic pass, db user/pass, ntfy, etc.
        .c1
        .c2
        .c3
      scripts/
        db_backup.sh      # MySQL/MariaDB dump
        files_backup.sh
        restore.sh
        verify_backup.sh
        verify_full_backup.sh
    postgres/
      job.conf            # Postgres config (DB_ENGINE=postgres, PG_HOST, PG_PORT)
      secrets/            # separate postgres credentials
        .c1               # ← can be a SHARED restic password (link to default's), or independent
        .c2               # postgres user
        .c3               # postgres password
      scripts/
        db_backup.sh      # Postgres dump
        restore.sh

/etc/systemd/system/
  backupd-db.timer                  # ← rename to backupd-default-db.timer (migration step)
  backupd-files.timer
  backupd-verify.timer
  backupd-postgres-db.timer         # NEW
  backupd-postgres-db.service       # NEW

/var/lock/
  backupd-default-db.lock           # ← rename from backupd-db.lock
  backupd-default-files.lock        # ← rename from backupd-files.lock
  backupd-postgres-db.lock          # NEW
```

### Should the postgres job share a restic repo with default?

Two options — neither is wrong:

- **Independent repos** (recommended): each job has its own `RCLONE_DB_PATH` (e.g. `backups/db-mysql/` and `backups/db-postgres/`). Cleaner isolation; one engine going wrong doesn't pollute the other's repo; restic check + retention apply per-engine. **Recommend this default.**
- **Shared repo:** both jobs write to the same `RCLONE_DB_PATH`. Snapshots distinguished by `engine:mysql` / `engine:postgres` tags. Slightly less rclone API traffic. Don't bother — the simplification isn't worth the coupling.

---

## Implementation plan (file-by-file)

### Pre-work

- Make sure you're on `feature/multi-engine` branched off `feature/postgres-support`. Rebase if upstream has moved.
- Re-read `lib/jobs.sh` (1113 lines), `lib/scheduler.sh` (job-aware sections around line 312), `lib/migration.sh`. The data layer is already there; you're filling in the gaps.

### 1. `lib/jobs.sh` — add `configure_job` (~150 lines)

This is the main new piece. A `configure_job <job_name>` function that walks the user through:

- Pick what to back up (database, files, both)
- If database: pick engine (mysql/mariadb/postgres) — only show available ones
- Collect creds — write to `$JOBS_DIR/$job_name/secrets/.c2`, `.c3` via `store_secret`
- For Postgres: collect `PG_HOST`, `PG_PORT`, write to `job.conf`
- Pick rclone remote + path
- Pick retention
- Pick schedule
- Trigger script generation (calls `generate_all_scripts` with the job-aware paths)
- Trigger timer creation (calls existing scheduler API with `job_name`)

**Key:** mostly a refactored copy of `lib/setup.sh:run_setup` Step 3-9, but pointed at a job's dirs instead of globals. Use `set_job_config` / `get_job_config` (existing in `lib/jobs.sh`) instead of `save_config` / `get_config_value`.

### 2. `lib/jobs.sh` — add `run_job_backup` (~50 lines)

A `run_job_backup <job_name> [db|files|both]` that:
- Resolves `$JOBS_DIR/$job_name/scripts/db_backup.sh` (or `files_backup.sh`)
- Sources the job's `job.conf` for env
- Executes the script

Used by both the systemd service unit and the interactive `backupd job run NAME` command.

### 3. `backupd.sh` — wire `backupd job` CLI dispatch (~100 lines)

In `parse_arguments`, add a case for `job`. Subcommands:

```
backupd job list                    → list_jobs / _job_status_text
backupd job create NAME             → create_job NAME
backupd job delete NAME [--force]   → delete_job NAME
backupd job clone SRC DST           → clone_job SRC DST
backupd job configure NAME          → configure_job NAME (the new one)
backupd job run NAME [TYPE]         → run_job_backup NAME TYPE
backupd job status [NAME]           → _job_status_text NAME (or all)
backupd job enable NAME / disable NAME
```

Help text update.

### 4. `lib/generators.sh` — make generation job-aware (~30 lines)

Add an optional `JOB_NAME` parameter to `generate_all_scripts` (default `"default"`). When `JOB_NAME != "default"`:
- Write scripts to `$JOBS_DIR/$JOB_NAME/scripts/` instead of `$SCRIPTS_DIR`
- Set `LOCK_FILE` placeholder to `/var/lock/backupd-${JOB_NAME}-db.lock` (and `-files.lock`)
- Use `$JOBS_DIR/$JOB_NAME/secrets/` as `SECRETS_DIR` placeholder

### 5. `lib/setup.sh` — keep `run_setup` for fresh installs (~20 lines)

Don't touch the existing `run_setup` flow much. After it produces the global config, the existing `lib/migration.sh` migrates that into the `default` job. Or: change `run_setup` to call `configure_job "default"` directly.

Decision point: simpler to leave the old flow alone and let migration handle it; or refactor `run_setup` to call `configure_job` from the start. **Recommend leaving the old flow alone for v3.1.x** to minimize risk; the migration code already handles the transition.

### 6. Migration — rename existing default-job timers to be `backupd-default-*` (~50 lines)

Currently the default job's timers are `backupd-db.timer` (no job prefix). For consistency in the new world, optional migration: rename to `backupd-default-db.timer`. **Or** keep the bare names as a special case for the default job (the existing `scheduler_disable` already does this). **Recommend keeping the special case** — less migration churn — and just make sure non-default jobs get the prefixed names. Document that the lock file fix below is the only mandatory migration.

### 7. Lock file fix in `lib/generators.sh` (~5 lines)

The hardcoded `LOCK_FILE="/var/lock/backupd-db.lock"` in the generator template needs to become a placeholder substituted to `/var/lock/backupd-${JOB_NAME}-db.lock` (or `backupd-db.lock` for default if you keep the back-compat carve-out).

Same for files backup script and the matching block in `lib/backup.sh:67-76` `show_running_backups`.

### 8. `tests/multi-engine/` — new test harness (~150 lines)

Mirror the structure of `tests/postgres/`:

- `tests/multi-engine/test_dual_install.sh` — set up two isolated DB engines (a MariaDB cluster on port 53306 + a Postgres cluster on port 55433), drive `backupd job create` for each, run both backups, verify both succeed, verify lock files don't collide, verify both restore wizards work.
- `tests/multi-engine/README.md` — setup recipe (initdb for postgres, mariadb-install-db for mariadb, restic binary path)

Use the existing `tests/postgres/` README as a template.

### 9. Version bump + CHANGELOG (~10 lines)

- `backupd.sh` `VERSION="3.2.4"` → `"3.3.0"` (minor — new feature, backwards-compatible)
- `CHANGELOG.md`: new entry covering the `backupd job` CLI completion + multi-engine via separate jobs + lock-file bug fix

---

## Open decisions for the picker-up

1. **Restic password — shared or per-job?** Each job currently has its own `secrets/.c1`. Sharing across jobs (symlink or copy) lets you mount one restic repo for all backups; independent passwords per job is cleaner isolation but doubles the password management. **Recommend independent — one password per job.**

2. **Default-job timer naming:** keep the legacy `backupd-db.timer` (no `default-` prefix) as a special case forever, or migrate to `backupd-default-db.timer`? Either is fine; the existing `scheduler_disable` (`lib/scheduler.sh:312`) already special-cases default. **Recommend keeping the special case** — less churn for existing installs.

3. **`backupd job configure` UX:** does it support non-interactive flags (`--engine postgres --pg-host ... --pg-port ...`)? Helpful for IaC users but adds surface area. **Recommend interactive-only for v1**; non-interactive is a follow-up issue.

4. **Per-engine snapshot tags:** the postgres support already adds `engine:postgres` tags. Should the default-job mysql backup also be retroactively re-tagged with `engine:mysql`? It already does so going forward — old snapshots just won't have the tag. The restore wizard handles missing tags by falling back to configured `DB_ENGINE`.

---

## Test setup recipe

For end-to-end testing on a Linux box without sudo:

### Postgres test cluster

```bash
TESTDIR=/tmp/backupd-test
PGDATA=$TESTDIR/pgdata
PGSOCK=$TESTDIR/sock
PGPORT=55433
mkdir -p "$PGDATA" "$PGSOCK"; chmod 700 "$PGDATA"
/usr/lib/postgresql/17/bin/initdb -D "$PGDATA" --auth-local=trust --auth-host=trust --username=postgres -E UTF8 -A trust
/usr/lib/postgresql/17/bin/pg_ctl -D "$PGDATA" -l "$TESTDIR/pg.log" -o "-p $PGPORT -k $PGSOCK -h ''" start
psql -h "$PGSOCK" -p "$PGPORT" -U postgres -d postgres -c 'SELECT version()'
```

### MariaDB test cluster

```bash
MYDATA=$TESTDIR/mydata
MYSOCK=$TESTDIR/my.sock
MYPORT=53306
mkdir -p "$MYDATA"
mariadb-install-db --datadir="$MYDATA" --auth-root-authentication-method=normal
mariadbd --no-defaults --datadir="$MYDATA" --port=$MYPORT --socket="$MYSOCK" \
  --skip-networking=0 --bind-address=127.0.0.1 \
  --pid-file=$TESTDIR/mariadb.pid &
sleep 3
mariadb --socket="$MYSOCK" -e 'SHOW DATABASES'
```

### restic binary (no install)

```bash
mkdir -p $TESTDIR/bin && cd $TESTDIR/bin
curl -sL https://github.com/restic/restic/releases/download/v0.18.0/restic_0.18.0_linux_amd64.bz2 -o restic.bz2
bunzip2 restic.bz2 && chmod +x restic
```

### Existing single-engine test

`tests/postgres/test_pg_pipeline.sh` proved the round-trip works for the postgres path. Run it first to make sure your environment is sane before tackling multi-engine.

---

## What NOT to do

- **Don't** add `DO_DATABASE_MYSQL` / `DO_DATABASE_POSTGRES` flags to a single job's `job.conf`. That competes with the existing jobs system and creates parallel state.
- **Don't** skip the lock-file fix — it's a pre-existing bug that affects multi-job in general, not just multi-engine.
- **Don't** rename the existing default-job timers in the same PR — keep the special case for back-compat.
- **Don't** invent a new secrets storage scheme. Reuse the existing `.c1`–`.c9` slot model, just per-job-dir.
- **Don't** mix the v3.1 jobs CLI completion work and the postgres-engine work into a single commit. Keep them as two ordered commits on the branch:
  1. *Complete the v3.1 backupd job CLI* (mostly mechanical wiring; standalone improvement)
  2. *Multi-engine support via job-per-engine + lock-file fix* (depends on commit 1)

---

## Pointers / references

- Issue #1 (Postgres support, single-engine — done): https://github.com/sg5web/backupd/issues/1
- Issue #2 (multi-engine — this work): https://github.com/sg5web/backupd/issues/2
- Issue #2 has a comment with locked design decisions from the original "DO_DATABASE_MYSQL flag" approach. **Those decisions are now superseded by this doc** — disregard them when implementing. (Worth adding a comment on #2 redirecting future readers here.)
- `lib/jobs.sh` — the existing job CRUD (1113 lines, line numbers stable as of `da0b66f`)
- `lib/scheduler.sh:312-340` — job-aware timer naming (`backupd-{job_name}-{type}.timer`)
- `lib/migration.sh` — legacy single-config → default job migration (already works)
- `tests/postgres/` — single-engine test harness; copy patterns for `tests/multi-engine/`
- `feature/postgres-support` branch — single-engine baseline; **do not delete or rebase away** — `feature/multi-engine` builds on it

---

## Step 1 for the next agent

```bash
git checkout feature/multi-engine
git log --oneline -5      # confirm you have the postgres-support commits
cat MULTI_ENGINE_PLAN.md  # this doc
bash tests/postgres/test_pg_pipeline.sh  # smoke test the baseline
gh issue view 2           # read the original issue for context
```

Then start with **Implementation step 3** above (`backupd.sh` CLI dispatch — wiring up `backupd job create/configure/run/list/delete`). That's the smallest first commit and unblocks everything else.
