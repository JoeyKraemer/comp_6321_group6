# Distributed Vector Search in ClickHouse

A Concordia COMP 6321 group project exploring ClickHouse as a distributed embeddings store for semantic search. The planned system combines a sharded ClickHouse cluster, approximate nearest-neighbor (ANN) search, and a LangGraph conversational RAG layer over a public arXiv dataset.

## Project goals

- Compare exact vector search with HNSW-based ANN search, including latency and recall@k.
- Use four ClickHouse nodes as two shards with two replicas per shard for node-level data failover.
- Explore hybrid vector search with SQL filters and aggregations.
- Build a LangGraph application that presents retrieved papers with an LLM-generated answer and sources.
- Evaluate quantization and, as the cluster supports it, replication and node-failure behavior.

The project proposal is in [`distributed-vector-search-in-clickhouse-course-project-proposal.md`](distributed-vector-search-in-clickhouse-course-project-proposal.md). Dataset ingestion, vector tables, retrieval tools, and benchmarking are planned work; they are not included in this initial scaffold.

## Local development stack

Docker Compose starts four ClickHouse nodes, a ClickHouse Keeper instance, and a minimal LangGraph API service. ClickHouse is configured as two shards with two replicas per shard. Tables using `ReplicatedMergeTree` can keep each shard available if one of its ClickHouse nodes fails. This is node-level data failover, not high availability for host, disk, or Keeper failures.

| Service | Host port | Purpose |
|---|---:|---|
| ClickHouse node 1 | `8123` (HTTP), `9000` (native) | Shard 1, replica 1 |
| ClickHouse node 2 | `8124` (HTTP), `9001` (native) | Shard 1, replica 2 |
| ClickHouse node 3 | `8125` (HTTP), `9002` (native) | Shard 2, replica 1 |
| ClickHouse node 4 | `8126` (HTTP), `9003` (native) | Shard 2, replica 2 |
| ClickHouse Keeper | `9181` | Coordination |
| LangGraph API | `2024` | Agent API and development UI |

## Requirements

- Docker Engine and Docker Compose v2

## Start and manage the cluster

Use `cluster.sh` to start the full stack, wait for all four ClickHouse nodes, and apply the replicated schema:

```bash
./cluster.sh up
```

The local ClickHouse credentials default to user `default` and password `clickhouse`. This default is for local development only. Override it when starting the stack:

```bash
CLICKHOUSE_PASSWORD='your-local-password' ./cluster.sh up
```

Other commands:

```bash
./cluster.sh status
./cluster.sh init
./cluster.sh down
```

`init` reapplies the idempotent SQL schema. `load` imports `data/arxiv-metadata-oai-snapshot.json` through the distributed table. `down` stops the stack but keeps named volume data; `docker compose down --volumes` removes the data too.

Open the LangGraph development UI at `http://localhost:2024`. The initial graph is a minimal placeholder, not yet connected to ClickHouse retrieval. ClickHouse nodes are configured with the `comp6321_cluster` cluster name; for example, from the first node:

```bash
docker compose exec clickhouse-1 clickhouse-client \
  --user default --password clickhouse \
  --query "SELECT hostName(), version() FROM clusterAllReplicas('comp6321_cluster', system.one)"
```

Stop the stack with `docker compose down`. Persistent database data remains in named Docker volumes; remove it with `docker compose down --volumes` when you want a clean reset.

## Apply SQL setup scripts

Shared schema and initialization queries live in tracked `.sql` files. Apply the replicated papers-table schema to the cluster with:

```bash
docker compose exec -T clickhouse-1 clickhouse-client \
  --user default --password clickhouse < sql/init.sql
```

Use the same `CLICKHOUSE_PASSWORD` value configured when the stack was started if you override the local default. The `arxiv.papers` Distributed table routes inserts by `cityHash64(id)` to one of two shards. Each shard has two `ReplicatedMergeTree` copies coordinated by Keeper.

The repository expects the arXiv metadata JSONL snapshot at `data/arxiv-metadata-oai-snapshot.json`. Each line is a JSON object. Load it after starting the cluster with:

```bash
./cluster.sh load
```

`sql/load_arxiv.sql` hashes arXiv's string IDs into `UInt64`, splits the whitespace-separated `categories` string into an array, and loads title and abstract. The snapshot does not contain embeddings, so `embedding` is initially empty; generate and populate vectors before running semantic vector search. The dataset is about 5.7 GB, is git-ignored, and is bind-mounted under ClickHouse's `user_files` directory. Loading reads the complete file and may take a while. `./cluster.sh load` appends rows, so avoid rerunning it unless you intend to insert the dataset again.

Run the automated failover test with `./cluster.sh test-failover`. It creates isolated temporary tables and test rows, verifies that one replica outage returns identical results, verifies that taking down both replicas of a shard makes the distributed query fail while the other shard remains queryable, then restarts the stopped nodes and checks recovery. It removes the test tables afterward. Avoid running it while other people are using this Compose cluster because it stops `clickhouse-1` and `clickhouse-2` briefly.

This Compose setup uses a single Keeper instance, so it is a development demonstration of ClickHouse node failover, not resilient coordination or production high availability.

## Planned search workflow

1. Load and shard the arXiv abstracts dataset (target size: at least 1 GB).
2. Generate 384-dimensional embeddings and store paper metadata with vectors in ClickHouse.
3. Create distributed vector-search tables and compare exact scans with HNSW ANN queries.
4. Add a LangGraph search tool that queries ClickHouse, then return an answer with paper citations.
5. Run scaling, recall, quantization, hybrid-query, and fault-tolerance experiments and record reproducible results.

See the proposal for the architecture, experiment plan, team areas, timeline, and references.
