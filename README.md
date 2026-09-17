# pubmed_handler

PubMed論文データをElasticsearchに投入し、BM25全文検索を行うためのリポジトリです。

Elasticsearch は Apptainer (HPC/Slurm 環境) または Docker で起動できます。

---

## リポジトリ構成

```
pubmed_handler/
├── env/                          # Apptainer + Slurm 環境 (現行)
│   ├── build_es.sh               # elasticsearch.sif のビルド
│   ├── run_es.sh                 # Elasticsearch 起動
│   ├── common.sh                 # 二重起動ガード
│   ├── smoke_test_slurm.sh       # 動作確認ジョブ
│   ├── index_slurm.sh            # 本番投入ジョブ
│   ├── serve_slurm.sh            # ES + JupyterLab 常駐ジョブ
│   └── README.md                 # Apptainer 環境の詳細手順
│
├── previous_env/                 # Docker 環境 (旧)
│   ├── docker-compose.yml
│   └── README.md
│
├── prepare_with_parquet/         # インデックス作成スクリプト (現行)
│   ├── prepare_elasticsearch_parquet_article.py   # articles のみ
│   ├── prepare_elasticsearch_parquet.py           # articles + sentences + labels
│   └── smoke_test_es.py                           # 少量データでの検証
│
├── archive_prepare/              # インデックス作成スクリプト (旧 / SQLite ベース)
│   ├── prepare_elasticsearch.py          # exact match アナライザー
│   ├── prepare_elasticsearch_stem.py     # porter_stem アナライザー
│   ├── prepare_elasticsearch_v2.py       # stem の安定版
│   ├── prepare_elasticnet.ipynb          # notebook 版 (article + sentence)
│   └── prepare_elasticsearch_pmc.ipynb   # PMC データ調査用
│
└── search_demo/                  # 検索デモ notebook
    ├── search_drugbank.ipynb
    ├── search_meddra.ipynb
    ├── search_pubchem.ipynb
    ├── search_rxnorm.ipynb
    ├── search_cell_ontology.ipynb
    └── overlap_sentence.ipynb
```

`sif/`・`data/`・`logs/` は実行時に作られます (git 管理外)。

---

## セットアップ (HPC)

Python 環境と SIF は共有の `0_ENV` から symlink で持ち込みます。

```bash
ln -s <0_ENV>/envs/vllm/.venv    .venv
ln -s <0_ENV>/envs/vllm/env.sif  env.sif
ln -s <0_ENV>/envs/vllm/uv.lock  uv.lock

mkdir -p data
ln -s <parquet の置き場> data/260420_pubmed

mkdir -p logs
```

Elasticsearch 用の SIF は別途ビルドします (初回のみ、login node で)。

```bash
./env/build_es.sh
```

詳細は [env/README.md](env/README.md) を参照してください。

---

## データ

インデックス作成には `text_data_handler` リポジトリで生成した PubMed parquet を使用します。

| ファイル | 行数 | 内容 |
|---|---|---|
| `combined_articles.parquet` | 38,201,553 | 1記事1行 |
| `combined_sentences.parquet` | 80,509,187 | 1文1行 |
| `combined_labels.parquet` | (未生成) | 1セクション1行 |

`DATA_DIR` 環境変数でデータディレクトリを指定します。スクリプトは
`${DATA_DIR}/260420_pubmed/` 配下を参照します。

### カラム名と ES フィールド名の対応

**parquet のカラム名と Elasticsearch のフィールド名は一致しません。**

| parquet | Elasticsearch |
|---|---|
| `abstract_lang` | `language` |
| `pub_type` | `publication_types` |
| その他 (`pmid`, `title`, `abstract`, `journal`, `year`, `mesh`, `abstract_truncated`) | 同名 |

`mesh` と `pub_type` は `"A|B|C"` 形式のパイプ区切り文字列です。投入時に
`|` で分割して配列として格納します。分割せずに `keyword` へ入れると全体が
1トークンになり、個別の語での絞り込みがヒットしなくなります。

---

## Elasticsearch の起動とインデックス作成

### Apptainer (HPC/Slurm) — 推奨

いずれもリポジトリルートから `sbatch` で投入します。

```bash
# 1. 動作確認 (少量データ。本番インデックスには触れない)
sbatch env/smoke_test_slurm.sh

# 2. 本番投入 (articles と sentences は分けて流す)
sbatch --export=ALL,TARGETS=articles  env/index_slurm.sh
sbatch --export=ALL,TARGETS=sentences env/index_slurm.sh

# 3. 常駐サービス (ES + JupyterLab)
sbatch env/serve_slurm.sh
```

**同時に 1 つの Elasticsearch しか動かせません。** `data/esdata` は NFS 上に
あるため、別ノードで 2 つ目が起動するとインデックスが壊れます。各スクリプトが
`squeue` を確認して重複を拒否します。

### Docker (ローカル開発)

```bash
cd previous_env
docker compose up -d
```

---

## インデックス作成スクリプトを直接実行する場合

Slurm ジョブ経由なら環境変数は自動で設定されます。手で動かす場合のみ以下が必要です。

```bash
export ES_HOST=http://localhost:9200
export ES_USER=elastic
export ES_PASSWORD=          # セキュリティ無効の場合は空
export DATA_DIR=/path/to/data
export TARGETS=all           # all | articles | sentences | labels (カンマ区切り可)

python prepare_with_parquet/prepare_elasticsearch_parquet.py
```

`.env` からの読み込みにも対応しています (`python-dotenv`)。

作成されるインデックス:

| インデックス名 | 粒度 | 主なフィールド |
|---|---|---|
| `pubmed_articles` | 1記事1doc | pmid, title, abstract, journal, year, mesh, publication_types |
| `pubmed_sentences` | 1文1doc | pmid, sent_id, sentence |
| `pubmed_labels` | 1セクション1doc | pmid, label_id, label, text |

parquet が存在しないインデックスは自動でスキップされます。

---

## アナライザー

全インデックスで **porter_stem** アナライザーを使用しています。

```
standard tokenizer → lowercase → porter_stem
```

`"running"` `"runs"` `"ran"` が同じ語幹 `"run"` にマッチします。
`mesh`・`journal`・`publication_types` 等の識別子フィールドは `keyword` 型 (exact match) です。

---

## 検索例

```python
from elasticsearch import Elasticsearch

es = Elasticsearch("http://localhost:9200")

res = es.search(
    index="pubmed_articles",
    body={
        "query": {
            "multi_match": {
                "query": "insulin resistance type 2 diabetes",
                "fields": ["title^2", "abstract"],
                "type": "best_fields"
            }
        },
        "size": 5
    }
)

for hit in res["hits"]["hits"]:
    print(hit["_source"]["pmid"], hit["_source"]["title"])
```

MeSH での絞り込み:

```python
res = es.search(
    index="pubmed_articles",
    body={
        "query": {
            "bool": {
                "must":   [{"match": {"abstract": "insulin resistance"}}],
                "filter": [{"term": {"mesh": "Humans"}}]
            }
        }
    }
)
```

---

## 旧スクリプト (archive_prepare) との違い

| 項目 | 旧 (archive_prepare) | 新 (prepare_with_parquet) |
|---|---|---|
| データソース | SQLite (.db) | Parquet |
| 読み込み | メモリ全展開 | ストリーミング (iter_batches) |
| Bulk | シングルスレッド | parallel_bulk (4スレッド) |
| アナライザー | exact / stem の2種 | porter_stem に統一 |
| インデックス | article / sentence | article / sentence / label |
| 接続設定 | ハードコード | 環境変数 / `.env` |

`archive_prepare/` のスクリプトは `ES_HOST` と `ES_PASSWORD` がハードコードされ、
参照する `DB_DIR` も現存しないパスのため、そのままでは動きません。
