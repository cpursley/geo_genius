#!/usr/bin/env bash
# Run the GeoGenius pgTAP suite with pg_prove -- the idiomatic TAP harness --
# inside the db container, where pg_prove is installed (see
# database/Dockerfile.postgres) and test/ is mounted read-only at /tests.
#
# pg_prove validates each file's declared plan, aggregates results, and returns
# a real exit code. A psql loop cannot: psql exits 0 even when a file aborts
# partway or emits fewer assertions than it planned, so plan mismatches and
# swallowed assertions pass silently.
#
# Usage:
#   ./test/pgtap/run.sh                      # whole suite
#   ./test/pgtap/run.sh resolution           # one folder
#   ./test/pgtap/run.sh resolution/test_spatial.sql
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/../../docker-compose.yml"

TARGET_SELECTOR="${1:-}"
TARGET="/tests/pgtap${TARGET_SELECTOR:+/$TARGET_SELECTOR}"

# Shared fixture helpers, run in filename order: extensions/schema-presence
# (00-setup.sql), then whatever fixture helpers later tasks add. These live
# outside test/pgtap/ so pg_prove never tries to run them as test files.
docker compose -f "$COMPOSE_FILE" exec -T db bash -lc '
  set -euo pipefail
  shopt -s nullglob
  for support in /tests/pgtap_support/*.sql; do
    psql -U postgres -d geo_genius_test -v ON_ERROR_STOP=1 -q -f "$support"
  done
'

exec docker compose -f "$COMPOSE_FILE" exec -T db \
  pg_prove -U postgres -d geo_genius_test -r --ext .sql "$TARGET"
