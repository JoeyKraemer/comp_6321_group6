# Distributed Vector Search in ClickHouse
### A Scalable Embeddings Store for AI Applications — Course Project Proposal

## 1. Overview

Modern AI applications — retrieval-augmented generation (RAG), semantic search, recommendation, and anomaly detection — depend on **vector embeddings**: high-dimensional numerical representations where semantically similar items become nearby points in vector space. The core database challenge behind these systems is **Approximate Nearest Neighbor (ANN) search** at scale: finding the k most similar vectors among millions, in milliseconds.

This project demonstrates how a **distributed analytical database (ClickHouse)** serves as a scalable embeddings store. We build a small semantic-search application over a 1GB+ public dataset, deployed on a multi-node ClickHouse cluster, and evaluate horizontal scaling, ANN vs. exact search, and hybrid vector + SQL querying.

**Why it fits the course:**

- Directly matches the syllabus category *"Embeddings stores"* (distributed AI/data systems)
- ClickHouse is a genuinely distributed, shared-nothing MPP columnar system — NoSQL-family analytics store listed on dbdb.io
- The dataset requirement (≥1GB) is naturally satisfied by embedding corpora at scale

## 2. System Architecture

```text
                    ┌──────────────────────────┐
                    │  arXiv abstracts / docs  │  1–5 GB public dataset
                    └────────────┬─────────────┘
                                 │  batch embedding
                    ┌────────────▼─────────────┐
                    │  Sentence-Transformer    │  e.g. all-MiniLM-L6-v2
                    │  (384-dim Float32 vecs)   │
                    └────────────┬─────────────┘
                                 │  INSERT (sharded)
        ┌────────────────────────▼─────────────────────────┐
        │            ClickHouse Distributed Cluster        │
        │                                                  │
        │  Node 1: ReplicatedMergeTree shard + HNSW index │
        │  Node 2: ReplicatedMergeTree shard + HNSW index │
        │  Node 3: ReplicatedMergeTree shard + HNSW index │
        │                                                  │
        │  Keeper (replication coordination)               │
        │  Distributed table (fan-out ANN + top-k merge)    │
        └────────────────────────┬─────────────────────────┘
                                 │  ANN query (cosine / L2)
                    ┌────────────▼─────────────┐
                    │  Mini RAG / search app   │  natural-language UI
                    └──────────────────────────┘
```

**Key components**

| Component | Choice | Role |
|---|---|---|
| Embedding model | MiniLM via ClickHouse `embed()` (query + doc embeddings inside the DB) | Text → vectors |
| Dataset | arXiv abstracts (Kaggle/Cornell, 1–5 GB), sharded Parquet files | Meets 1GB requirement |
| Storage engine | `ReplicatedMergeTree` with `Array(Float32)` column | Sharded + replicated vector store |
| ANN index | HNSW `vector_similarity` index (usearch-based, with quantization: i8 / f16 / BFloat16) | Fast approximate search |
| Cluster | 3 ClickHouse nodes + ClickHouse Keeper on cloud VMs (Docker Compose) | Distributed execution |
| AI orchestration | **LangChain + LangGraph** | Retrieval-augmented generation: conversational UI, LLM answer synthesis on top of ClickHouse retrieval |
| Application | LangGraph agent + ClickHouse Play UI | Live demo front end |

## 3. Search Architecture (How Queries Work)

The search flow is a **RAG pipeline** with two layers: **LangGraph/LangChain** provides the conversational agent and answer synthesis, while **ClickHouse does the heavy lifting** — embedding and ANN retrieval happen inside the distributed database via `embed()` and SQL. The division of labor: the LLM only phrases the answer; the distributed engine does the retrieval.

```text
[User question] → LangGraph agent → ClickHouse embed() + ANN SQL (retrieval)
                      ↓ top-k chunks
                 LLM (answer synthesis, cited sources)
                      ↓
                 [Natural-language answer + retrieved papers]
```

### 3.1 In-database embedding — ClickHouse `embed()`

Modern ClickHouse (25.x+) ships an `embed()` function that runs the MiniLM model (ONNX) **inside the database** — no external model service. Query-time embedding:

```sql
WITH embed('scaling laws in language models') AS qvec
SELECT title, categories, cosineDistance(embedding, qvec) AS dist
FROM arxiv_papers                            -- the Distributed table
ORDER BY dist ASC
LIMIT 10                                     -- ANN index kicks in automatically
```

Fallback if `embed()` is unstable on our pinned version: a tiny Python script embeds the query with `sentence-transformers` before issuing the SQL (10 lines, kept as insurance).

### 3.2 The search itself — just SQL

- **ANN (fast):** the HNSW `vector_similarity` index is used automatically when the query's distance function matches the index definition:
  ```sql
  ALTER TABLE arxiv_papers ADD INDEX vec_idx embedding
    TYPE vector_similarity('hnsw', 'cosineDistance', 384);
  ```
- **Exact baseline:** same query on a table *without* the index → full columnar scan. Showing the two side by side (with `Elapsed` timing output) is the ANN-vs-exact demo.
- **Hybrid vector + SQL:** add WHERE/GROUP BY to the same query:
  ```sql
  SELECT title, categories, min(dist) FROM (
    SELECT title, categories,
           cosineDistance(embedding, {q:Array(Float32)}) AS dist
    FROM arxiv_papers WHERE categories LIKE '%cs.DB%'
  ) GROUP BY categories ORDER BY min(dist) LIMIT 5;
  ```

### 3.4 LangGraph/LangChain agent layer

A small LangGraph agent (one tool node, one answer node) turns the SQL retrieval into a conversational RAG demo:

```python
from langchain_core.tools import tool
from langgraph.prebuilt import create_react_agent

@tool
def search_arxiv(query: str) -> str:
    """Semantic search over arXiv papers. Returns top-5 titles with distances."""
    rows = ch_client.query("""
        WITH embed({q:String}) AS qvec
        SELECT title, cosineDistance(embedding, qvec) AS dist
        FROM arxiv_papers ORDER BY dist ASC LIMIT 5
    """, parameters={"q": query}).result_rows
    return "\n".join(f"{t} (dist={d:.3f})" for t, d in rows)

agent = create_react_agent(llm, [search_arxiv])
# User: "What are the key papers on scaling laws?" → agent calls the tool,
# ClickHouse embeds + retrieves, LLM writes a cited answer.
```

Why LangGraph here: the agent decides *when* and *how* to query the distributed engine, keeps conversation state (LangGraph's graph-based state machine), and renders results as natural answers — while ClickHouse remains the system doing all data work. Fallback if time runs short: the same retrieval works directly in the ClickHouse Play UI, so the distributed demo never depends on the LLM layer.

### 3.5 Demo tip

Run the LangGraph agent on the projector, and next to it run the same retrieval as pure SQL in the ClickHouse Play UI with timing output (`Elapsed: 0.05 sec, Processed 2M rows`) — the juxtaposition of "human-friendly AI app" and "distributed engine under the hood" is the story to tell.

## 4. Demo Script (15%)

1. **Semantic search in action** — type a natural-language query ("papers about scaling laws in language models") → embedded → ANN search across the cluster → top-k results in milliseconds.
2. **Exact vs. approximate** — brute-force scan vs. HNSW index: show the latency gap and measure **recall@k** to prove ANN quality.
3. **Hybrid vector + SQL query** — e.g. "similar papers, published after 2023, grouped by category" — a capability dedicated vector DBs struggle with, enabled by ClickHouse's analytical engine.
4. **Horizontal scaling** — same query on 1 vs. 2 vs. 3 nodes; show latency and throughput improvements from parallel fan-out ANN search.
5. **Fault tolerance** — kill a replica mid-query; the query still succeeds (replication demo).

## 5. Evaluation Plan

| Experiment | Metric | Expected finding |
|---|---|---|
| Exact scan vs. HNSW ANN | latency, recall@k | ANN gives 10–100× speedup with ≥95% recall |
| 1 → 2 → 3 nodes | query latency, QPS | near-linear scaling until network/merge overhead |
| Quantization (f32 → bf16 → i8) | index size, latency, recall | memory savings vs. quality tradeoff |
| Hybrid filtered vector search | latency vs. filter selectivity | cost of pre- vs. post-filtering |
| (Optional) vs. FAISS single-node | end-to-end latency | what distribution buys over a single machine |

Each configuration is run warm/cold, multiple trials, results plotted (speedup curve is the report centerpiece).

## 6. Deliverables Mapping

- **Live demo (15%):** semantic search app + scaling + fault-tolerance script (Section 3)
- **Presentation (7%):** embeddings → ANN problem → HNSW → distributed fan-out → results
- **Report (3%, 4 pages, VLDB style):** architecture (1 p), experimental setup (1 p), results/plots (1.5 p), discussion incl. HNSW internals & scaling limits (0.5 p)

## 7. Distributed-Systems Concepts Covered

- Sharding of high-dimensional data across nodes
- Two-phase distributed aggregation (per-shard top-k, merged at coordinator)
- Replication and fault tolerance (ReplicatedMergeTree, Keeper)
- ANN graph traversal (HNSW) and its distributed implications
- Quantization and memory/accuracy tradeoffs
- Amdahl's law in practice: where parallel ANN stops paying off

## 8. Team Split (5 members, 4 work areas)

The rubric requires each member to present **one distributed feature** (at least 3 features). The project splits into four work areas; the infrastructure area carries the most build load and gets two people. **All members contribute to the report** — area D's lead integrates and edits the final version.

| Area | Members | Owns (build) | Presents (distributed feature) |
|---|---|---|---|
| **A — Clustering / infrastructure** | 2 | Cloud VMs, Docker Compose cluster (3 nodes + Keeper), `ReplicatedMergeTree` + `Distributed` tables, deployment scripts; shard-key design | **Member 1: Sharding & distributed ingest** · **Member 2: Replication** (data distribution, shard keys, shard-per-file layout) |
| **B — Benchmarks** | 1 | Exact vs. ANN (latency, recall@k), quantization variants (f32/bf16/i8), 1→2→3 node scaling measurements, multiple trials warm/cold | **Scaling & ANN fan-out**: parallel per-shard HNSW search, per-shard top-k merge, speedup curves |
| **C — LangGraph / AI application** | 1 | LangGraph/LangChain agent, LLM API integration, `search_arxiv` tool, conversational RAG UI, hybrid vector+SQL queries | **Hybrid querying**: vector search combined with distributed SQL filters/aggregation |
| **D — Evaluation / reporting lead** | 1 | Fault-tolerance experiments (kill-a-node, kill-a-VM), experiment design review, plots & figures, VLDB report integration, slides, demo rehearsal | **Fault tolerance**: query survives node failure, Keeper coordination |

**Writing rule:** every member writes the report section for their own area (Abstract and Introduction are drafted jointly); D's member is responsible for the final document: layout, VLDB format compliance, consistency, and the results/figures section.

**Demo script ownership:** A's two members open (cluster overview, sharding, replication), B shows ANN-vs-exact and the scaling chart, C demos the conversational agent and hybrid query, D closes with kill-a-node — five features, five presenters, inside the 5-minute slot.

## 9. Timeline (parallel workstreams)

Four weeks, four parallel tracks. A is the critical path — everything else starts against a minimal (even single-node) setup and scales up once the cluster lands.

| Week | A — Infrastructure (2 people) | B — Benchmarks | C — LangGraph | D — Evaluation/Reporting |
|---|---|---|---|---|
| **1** | Cloud VMs, Docker Compose cluster + Keeper, Replicated/Distributed tables; download Kaggle data, Parquet sharding (>3 files) | Download dataset early; design benchmark suite & metrics (latency, recall@k); dry-run on a single local ClickHouse container | Prototype agent locally against a small sample table (LangGraph skeleton, tool calling, LLM integration) | Set up experiment tracking (result logs, plot scripts); draft report skeleton in VLDB LaTeX; collect related work |
| **2** | Sharding keys, full ingestion on 3 nodes, bulk `embed()` pipeline; **cluster ready** | Port benchmark suite to the cluster; first exact-vs-ANN + quantization numbers | Point `search_arxiv` tool at the real Distributed table; hybrid vector+SQL queries; agent end-to-end | Start scaling experiments (1 vs. 2 vs. 3 nodes) as soon as cluster is up; begin methods section |
| **3** | Support & fix-ups: index build issues, rebalancing, deployment polish; first full run-through of the infra demo | Full benchmark campaign: multiple trials, warm/cold cache; finalize scaling & recall plots | Polish agent for demo (conversation state, cited answers); rehearse hybrid-query moment | Fault-tolerance experiments (kill-a-node, kill-a-VM); integrate everyone's sections; results & discussion |
| **4** | Demo environment freeze & backup snapshot (restore-tested) | Final benchmark numbers locked (no more changes); contribute results section | Agent frozen; fallback (Play UI) rehearsed | Final report & slides integration; full timed rehearsal (5 min presentation + 5 min demo) |

**Coordination checkpoints (all members):** end of week 1 (cluster architecture frozen), mid-week 2 (cluster live — go/no-go), end of week 3 (all experiments done), mid-week 4 (full dry run).

## 10. Risks & Mitigations

- **HNSW index is still maturing in ClickHouse** → pin a recent stable version and validate early in week 1–2; fallback is exact-search scaling demo (still strong)
- **Embedding 1GB+ of text is slow on CPU** → use a pre-embedded dataset (e.g., GloVe/fastText) or embed overnight
- **Memory pressure from in-memory HNSW** → use quantization (project becomes stronger, not weaker)

## 11. References

- ClickHouse docs — Exact and Approximate Vector Search: https://clickhouse.com/docs/engines/table-engines/mergetree-family/annindexes
- ClickHouse blog — Vector Search with ClickHouse: https://clickhouse.com/blog/vector-search-clickhouse-p1
- ClickHouse RFC — Vector Search Improvements / index 2.0: https://github.com/ClickHouse/ClickHouse/issues/104122
- NoSQL system directory: https://dbdb.io/
- VLDB report style: http://vldb.org/pvldb/vol14-formatting/