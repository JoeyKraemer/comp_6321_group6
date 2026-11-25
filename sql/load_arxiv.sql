INSERT INTO arxiv.papers (id, title, abstract, categories, embedding)
SELECT
    cityHash64(id) AS id,
    title,
    abstract,
    arrayFilter(category -> category != '', splitByChar(' ', trimBoth(categories))) AS categories,
    CAST([], 'Array(Float32)') AS embedding
FROM file(
    'arxiv-metadata-oai-snapshot.json',
    'JSONEachRow',
    'id String, title String, abstract String, categories String'
);
