# Distributed Vector Search in ClickHouse

A Concordia COMP 6321 group project exploring ClickHouse as a distributed embeddings store for semantic search. The planned system combines a sharded ClickHouse cluster, approximate nearest-neighbor (ANN) search, and a LangGraph conversational RAG layer over a public arXiv dataset.

## Project goals

- Compare exact vector search with HNSW-based ANN search, including latency and recall@k.
- Measure search performance as the ClickHouse cluster scales from one to three nodes.
- Explore hybrid vector search with SQL filters and aggregations.
- Build a LangGraph application that presents retrieved papers with an LLM-generated answer and sources.
- Evaluate quantization and, as the cluster supports it, replication and node-failure behavior.

The project proposal is in [`distributed-vector-search-in-clickhouse-course-project-proposal.md`](distributed-vector-search-in-clickhouse-course-project-proposal.md). Dataset ingestion, vector tables, retrieval tools, and benchmarking are planned work; they are not included in this initial scaffold.

## Local development stack

Docker Compose starts three ClickHouse nodes, a ClickHouse Keeper instance, and a minimal LangGraph API service. The ClickHouse nodes form a three-shard development cluster. This scaffold does not yet configure replicated tables or provide replica-level fault tolerance.

| Service | Host port | Purpose |
|---|---:|---|
| ClickHouse node 1 | `8123` (HTTP), `9000` (native) | Default query endpoint |
| ClickHouse node 2 | `8124` (HTTP), `9001` (native) | Cluster shard 2 |
| ClickHouse node 3 | `8125` (HTTP), `9002` (native) | Cluster shard 3 |
| ClickHouse Keeper | `9181` | Coordination |
| LangGraph API | `2024` | Agent API and development UI |

## Requirements

- Docker Engine and Docker Compose v2

## Start the services

```bash
docker compose up --build
```

The local ClickHouse credentials default to user `default` and password `clickhouse`. This default is for local development only. Override it before starting the stack:

```bash
CLICKHOUSE_PASSWORD='your-local-password' docker compose up --build
```

Open the LangGraph development UI at `http://localhost:2024`. The initial graph is a minimal placeholder, not yet connected to ClickHouse retrieval. ClickHouse nodes are configured with the `comp6321_cluster` cluster name; for example, from the first node:

```bash
docker compose exec clickhouse-1 clickhouse-client \
  --user default --password clickhouse \
  --query "SELECT hostName(), version() FROM clusterAllReplicas('comp6321_cluster', system.one)"
```

Stop the stack with `docker compose down`. Persistent database data remains in named Docker volumes; remove it with `docker compose down --volumes` when you want a clean reset.

## Planned search workflow

1. Load and shard the arXiv abstracts dataset (target size: at least 1 GB).
2. Generate 384-dimensional embeddings and store paper metadata with vectors in ClickHouse.
3. Create distributed vector-search tables and compare exact scans with HNSW ANN queries.
4. Add a LangGraph search tool that queries ClickHouse, then return an answer with paper citations.
5. Run scaling, recall, quantization, hybrid-query, and fault-tolerance experiments and record reproducible results.

See the proposal for the architecture, experiment plan, team areas, timeline, and references.
