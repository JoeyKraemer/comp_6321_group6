#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

COMMAND="${1:-up}"

clickhouse_query() {
    local query="$1"
    docker compose exec -T clickhouse-1 sh -c \
        'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "$1"' \
        sh "$query"
}

wait_for_clickhouse() {
    local attempt

    printf 'Waiting for ClickHouse nodes'
    for attempt in $(seq 1 60); do
        if clickhouse_query "SELECT count() FROM clusterAllReplicas('comp6321_cluster', system.one)" 2>/dev/null | tr -d '\r' | grep -qx '4'; then
            printf '\nAll four ClickHouse nodes are responding.\n'
            return 0
        fi
        printf '.'
        sleep 2
    done

    printf '\nClickHouse cluster did not become ready in time.\n' >&2
    docker compose ps --all >&2
    return 1
}

case "$COMMAND" in
    up)
        docker compose up -d --build
        wait_for_clickhouse
        printf 'Applying replicated database schema...\n'
        docker compose exec -T clickhouse-1 sh -c \
            'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery' \
            < sql/init.sql
        printf 'Checking shard and replica layout...\n'
        clickhouse_query "SELECT shard_num, count() AS replicas FROM system.clusters WHERE cluster='comp6321_cluster' GROUP BY shard_num ORDER BY shard_num FORMAT TSV"
        printf 'Cluster is ready.\n'
        ;;
    init)
        wait_for_clickhouse
        docker compose exec -T clickhouse-1 sh -c \
            'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery' \
            < sql/init.sql
        ;;
    load)
        if [[ ! -f data/arxiv-metadata-oai-snapshot.json ]]; then
            printf 'Missing data/arxiv-metadata-oai-snapshot.json\n' >&2
            exit 1
        fi
        wait_for_clickhouse
        docker compose exec -T clickhouse-1 sh -c \
            'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"' \
            < sql/load_arxiv.sql
        ;;
    test-failover)
        "$ROOT_DIR/scripts/test_failover.sh"
        ;;
    status)
        docker compose ps --all
        ;;
    down)
        docker compose down
        ;;
    *)
        printf 'Usage: %s [up|init|load|test-failover|status|down]\n' "$0" >&2
        exit 2
        ;;
esac
