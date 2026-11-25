CREATE DATABASE IF NOT EXISTS arxiv ON CLUSTER comp6321_cluster;

CREATE TABLE IF NOT EXISTS arxiv.papers_local ON CLUSTER comp6321_cluster
(
    id UInt64,
    title String,
    abstract String,
    categories Array(String),
    embedding Array(Float32),
    updated_at DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/arxiv/papers_local',
    '{replica}'
)
ORDER BY id;

CREATE TABLE IF NOT EXISTS arxiv.papers ON CLUSTER comp6321_cluster
AS arxiv.papers_local
ENGINE = Distributed(
    comp6321_cluster,
    arxiv,
    papers_local,
    cityHash64(id)
);
