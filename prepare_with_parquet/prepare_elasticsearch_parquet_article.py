'''
 # @ Author: Yohei Ohto
 # @ Create Time: 2026-05-21
 # @ Description:
 #   PubMed combined_articles.parquet -> Elasticsearch
 #   index: pubmed_articles (porter_stem, BM25)
'''

import os
from pathlib import Path

import pyarrow.parquet as pq
from dotenv import load_dotenv
from elasticsearch import Elasticsearch, helpers

load_dotenv()

# =========================================================
# Config
# =========================================================

ES_HOST     = os.environ.get("ES_HOST", "http://elasticsearch:9200")
ES_USER     = os.environ.get("ES_USER", "elastic")
ES_PASSWORD = os.environ.get("ES_PASSWORD", "")
BULK_SIZE   = 5_000

DATA_DIR       = Path(os.environ.get("DATA_DIR", "."))
PARQUET_PATH   = DATA_DIR / "260420_pubmed" / "combined_articles.parquet"
INDEX_NAME     = "pubmed_articles"


# =========================================================
# Mapping
# =========================================================

MAPPING = {
    "settings": {
        "analysis": {
            "analyzer": {
                "english_stemmed": {
                    "tokenizer": "standard",
                    "filter": ["lowercase", "porter_stem"],
                }
            }
        }
    },
    "mappings": {
        "properties": {
            "pmid":              {"type": "long"},
            "title":             {"type": "text", "analyzer": "english_stemmed"},
            "abstract":          {"type": "text", "analyzer": "english_stemmed"},
            "journal":           {"type": "keyword"},
            "language":          {"type": "keyword"},
            "year":              {"type": "integer"},
            "mesh":              {"type": "keyword"},
            "publication_types": {"type": "keyword"},
            "abstract_truncated":{"type": "integer"},
        }
    },
}


# =========================================================
# Action generator
# =========================================================

def generate_actions(parquet_path):
    pf = pq.ParquetFile(parquet_path)
    for batch in pf.iter_batches(batch_size=BULK_SIZE):
        d = batch.to_pydict()
        for i in range(len(d["pmid"])):
            mesh     = d["mesh"][i]
            pub_type = d["pub_type"][i]

            yield {
                "_index": INDEX_NAME,
                "_id":    d["pmid"][i],
                # ES のフィールド名は parquet のカラム名と一致しない
                #   abstract_lang -> language / pub_type -> publication_types
                #
                # mesh と pub_type は "A|B|C" 形式の文字列。分割せずに
                # keyword へ入れると全体が1トークンになり、個別の語での
                # 絞り込みがヒットしなくなるため split する。
                "_source": {
                    "pmid":              d["pmid"][i],
                    "title":             d["title"][i] or "",
                    "abstract":          d["abstract"][i] or "",
                    "journal":           d["journal"][i] or "",
                    "language":          d["abstract_lang"][i] or "",
                    "year":              d["year"][i],
                    "mesh":              mesh.split("|") if mesh else [],
                    "publication_types": pub_type.split("|") if pub_type else [],
                    "abstract_truncated":d["abstract_truncated"][i],
                },
            }


# =========================================================
# Main
# =========================================================

if __name__ == "__main__":

    es = Elasticsearch(
        ES_HOST,
        basic_auth=(ES_USER, ES_PASSWORD),
        request_timeout=60,
    )
    print(f"Connected: {es.info()['version']['number']}")

    meta = pq.read_metadata(PARQUET_PATH)
    print(f"Parquet rows: {meta.num_rows:,}")

    if es.indices.exists(index=INDEX_NAME):
        print(f"Index '{INDEX_NAME}' exists → deleting")
        es.indices.delete(index=INDEX_NAME)
    es.indices.create(index=INDEX_NAME, body=MAPPING)
    print(f"Index '{INDEX_NAME}' created")

    success, failed = 0, 0
    for ok, info in helpers.parallel_bulk(
        es,
        generate_actions(PARQUET_PATH),
        chunk_size=BULK_SIZE,
        thread_count=4,
        raise_on_error=False,
    ):
        if ok:
            success += 1
        else:
            failed += 1

    es.indices.refresh(index=INDEX_NAME)
    count = es.count(index=INDEX_NAME)["count"]
    print(f"Indexed: {success:,}, Failed: {failed:,}, Final count: {count:,}")
