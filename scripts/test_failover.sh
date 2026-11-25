#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NODES=(clickhouse-1 clickhouse-2 clickhouse-3 clickhouse-4)
TEST_DATABASE="failover_test"
TEST_TABLE="rows_local"
DISTRIBUTED_TABLE="rows"
BASELINE=""
TEST_DATABASE_CREATED=0

ch_query() {
    local node="$1"
    local query="$2"
    docker compose exec -T "$node" sh -c \
        'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "$1"' \
        sh "$query"
}

wait_for_node() {
    local node="$1"
    local attempt

    for attempt in $(seq 1 60); do
        if ch_query "$node" "SELECT 1" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    printf 'Timed out waiting for %s.\n' "$node" >&2
    return 1
}

restore_nodes() {
    local node
    set +e
    docker compose start "${NODES[@]}" >/dev/null
    for node in "${NODES[@]}"; do
        wait_for_node "$node" || true
    done
    if [[ "$TEST_DATABASE_CREATED" -eq 1 ]]; then
        ch_query clickhouse-1 "DROP DATABASE IF EXISTS ${TEST_DATABASE} ON CLUSTER comp6321_cluster SYNC" >/dev/null 2>&1 || true
    fi
}

trap restore_nodes EXIT INT TERM

printf 'Checking that all four nodes are online...\n'
for node in "${NODES[@]}"; do
    wait_for_node "$node"
done

printf 'Preparing isolated failover test tables...\n'
ch_query clickhouse-1 "DROP DATABASE IF EXISTS ${TEST_DATABASE} ON CLUSTER comp6321_cluster SYNC"
ch_query clickhouse-1 "CREATE DATABASE ${TEST_DATABASE} ON CLUSTER comp6321_cluster"
TEST_DATABASE_CREATED=1
ch_query clickhouse-1 "CREATE TABLE ${TEST_DATABASE}.${TEST_TABLE} ON CLUSTER comp6321_cluster (id UInt64, label String) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/${TEST_DATABASE}/${TEST_TABLE}', '{replica}') ORDER BY id"
ch_query clickhouse-1 "CREATE TABLE ${TEST_DATABASE}.${DISTRIBUTED_TABLE} ON CLUSTER comp6321_cluster AS ${TEST_DATABASE}.${TEST_TABLE} ENGINE = Distributed(comp6321_cluster, ${TEST_DATABASE}, ${TEST_TABLE}, cityHash64(id))"

printf 'Seeding one test row per shard...\n'
ch_query clickhouse-1 "INSERT INTO ${TEST_DATABASE}.${TEST_TABLE} VALUES (1001, 'shard-one')"
ch_query clickhouse-3 "INSERT INTO ${TEST_DATABASE}.${TEST_TABLE} VALUES (2002, 'shard-two')"
BASELINE="$(ch_query clickhouse-1 "SELECT id, label FROM ${TEST_DATABASE}.${DISTRIBUTED_TABLE} ORDER BY id FORMAT TSV")"
EXPECTED=$'1001\tshard-one\n2002\tshard-two'
if [[ "$BASELINE" != "$EXPECTED" ]]; then
    printf 'Baseline mismatch. Expected:\n%s\nGot:\n%s\n' "$EXPECTED" "$BASELINE" >&2
    exit 1
fi
printf 'Baseline query sees both shards.\n'

printf 'Stopping clickhouse-1; its shard partner should keep the result unchanged...\n'
docker compose kill clickhouse-1 >/dev/null
ONE_NODE_RESULT="$(ch_query clickhouse-2 "SELECT id, label FROM ${TEST_DATABASE}.${DISTRIBUTED_TABLE} ORDER BY id FORMAT TSV")"
if [[ "$ONE_NODE_RESULT" != "$BASELINE" ]]; then
    printf 'FAIL: query changed with clickhouse-1 down.\nBefore:\n%s\nAfter:\n%s\n' "$BASELINE" "$ONE_NODE_RESULT" >&2
    exit 1
fi
printf 'PASS: one-replica outage returns the same rows.\n'

printf 'Stopping clickhouse-2 as well; the distributed query should fail because shard 1 is unavailable...\n'
docker compose kill clickhouse-2 >/dev/null
if FAILURE="$(ch_query clickhouse-3 "SELECT id, label FROM ${TEST_DATABASE}.${DISTRIBUTED_TABLE} ORDER BY id FORMAT TSV" 2>&1)"; then
    printf 'FAIL: distributed query succeeded with both shard-1 replicas down.\n' >&2
    exit 1
fi
printf 'PASS: distributed query failed with both shard-1 replicas down.\n%s\n' "$FAILURE"
PARTIAL="$(ch_query clickhouse-3 "SELECT id, label FROM ${TEST_DATABASE}.${TEST_TABLE} ORDER BY id FORMAT TSV")"
if [[ "$PARTIAL" != $'2002\tshard-two' ]]; then
    printf 'FAIL: surviving shard returned unexpected rows:\n%s\n' "$PARTIAL" >&2
    exit 1
fi
printf 'Surviving shard still returns:\n%s\n' "$PARTIAL"

printf 'Restarting failed nodes and checking full result recovery...\n'
docker compose start clickhouse-1 clickhouse-2 >/dev/null
wait_for_node clickhouse-1
wait_for_node clickhouse-2
ch_query clickhouse-1 "SYSTEM SYNC REPLICA ${TEST_DATABASE}.${TEST_TABLE}"
RECOVERED="$(ch_query clickhouse-1 "SELECT id, label FROM ${TEST_DATABASE}.${DISTRIBUTED_TABLE} ORDER BY id FORMAT TSV")"
if [[ "$RECOVERED" != "$BASELINE" ]]; then
    printf 'FAIL: query did not recover to baseline.\nBefore:\n%s\nAfter:\n%s\n' "$BASELINE" "$RECOVERED" >&2
    exit 1
fi
printf 'PASS: recovered cluster returns the original rows.\n'

ch_query clickhouse-1 "DROP DATABASE ${TEST_DATABASE} ON CLUSTER comp6321_cluster SYNC"
BASELINE=""
printf 'Failover test passed; temporary test tables were removed.\n'
