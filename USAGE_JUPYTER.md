# Jupyter (Python) から PubMed を検索する

コードから検索して、結果をそのまま解析に回すための手順です。
ブラウザで手軽に検索したいだけなら [USAGE_KIBANA.md](USAGE_KIBANA.md) の方が簡単です。

---

## 1. 起動する

Elasticsearch は常駐していません。**使うたびにジョブを投げて立ち上げます。**

```bash
cd /workspace/filesrv01/yoshikawa/260805_make_biore_ds/pubmed_handler
sbatch env/serve_slurm.sh
tail -f logs/pubmed_es_jupyter_<jobid>.out
```

ログに SSH トンネルのコマンドと接続 URL が出ます。**ポートとトークンは毎回変わる**
ので、必ずログを見てください。

```bash
# run this in ANOTHER terminal on the login node, and keep it open
ssh -N -L <jupyter_port>:localhost:<jupyter_port> -L <kibana_port>:localhost:<kibana_port> -p 49152 <node>
```

トンネルを張ったまま、ログに出た JupyterLab の URL をブラウザで開きます。

```text
http://localhost:<jupyter_port>/?token=<token>
```

起動直後は接続を拒否されることがあります。JupyterLab の起動には接続情報が
表示されてから 1 分ほどかかるので、待ってから再読み込みしてください。

終了するときは `scancel <jobid>` です。**使い終わったら必ず落としてください。**

---

## 2. 接続する

Elasticsearch は同じ計算ノードで動いているので、設定なしでそのまま繋がります。

```python
from elasticsearch import Elasticsearch

es = Elasticsearch("http://localhost:9200")
es.info()["version"]["number"]
```

---

## 3. フィールドの型で書き方を使い分ける

これを外すとヒットしません。

| 対象 | 型 | 使うクエリ |
|---|---|---|
| `title` `abstract` `sentence` | text (語幹あり) | `match` / `match_phrase` |
| `mesh` `journal` `publication_types` `language` | keyword | `term` / `terms` |
| `year` `pmid` `sent_id` | 数値 | `range` |

```python
# text: stemmed match ("running" also matches "run")
{"match": {"abstract": "cancer"}}

# text: exact phrase
{"match_phrase": {"abstract": "insulin resistance"}}

# keyword: exact match only
{"term": {"mesh": "Humans"}}

# keyword: any of
{"terms": {"mesh": ["Humans", "Mice"]}}

# numeric range
{"range": {"year": {"gte": 2020}}}
```

---

## 4. 組み合わせる

`bool` で束ねます。**スコアが必要なものだけ `must` に置き、単なる絞り込みは
`filter` に置いてください。** `filter` はスコア計算をせずキャッシュも効くため、
3,800万件に対しては速度がはっきり変わります。

```python
query = {
    "bool": {
        "must": [
            {"match_phrase": {"abstract": "insulin resistance"}},
        ],
        "filter": [
            {"term": {"mesh": "Humans"}},
            {"range": {"year": {"gte": 2020}}},
        ],
        "must_not": [
            {"term": {"mesh": "Animals"}},
        ],
    }
}

res = es.search(
    index="pubmed_articles",
    query=query,
    size=10,
    source=["pmid", "year", "journal", "title"],   # return only what you need
)

print(res["hits"]["total"]["value"], "hits")

for hit in res["hits"]["hits"]:
    s = hit["_source"]
    print(s["year"], s["pmid"], s["title"][:80])
```

`source` で列を絞るのは、Kibana で表示する列を選ぶのと同じ効果です。
abstract まで毎回返すと転送量が無駄になります。

---

## 5. keyword の候補を調べる

`mesh` などは完全一致なので、正確な値を知らないと検索できません。
集計を使うと、条件に合う文書の中で頻出する値を一覧できます。
Kibana の「フィールド一覧をクリックすると上位の値が出る」のと同じことです。

```python
res = es.search(
    index="pubmed_articles",
    query={"match": {"abstract": "cancer"}},
    size=0,
    aggs={"top_mesh": {"terms": {"field": "mesh", "size": 30}}},
)

for b in res["aggregations"]["top_mesh"]["buckets"]:
    print(f"{b['doc_count']:>9,}  {b['key']}")
```

`journal`・`publication_types`・`language`・`year` でも同じように使えます。

---

## 6. 件数だけ知りたい

```python
es.count(index="pubmed_articles", query=query)["count"]
```

---

## 7. 1 万件を超えて取り出す

**`size` は最大 10,000 です。** それ以上は `scan` を使います。

```python
from elasticsearch.helpers import scan

hits = scan(
    es,
    index="pubmed_articles",
    query={"query": query},
    _source=["pmid", "year", "title"],
    preserve_order=False,     # much faster when order does not matter
)

pmids = [h["_source"]["pmid"] for h in hits]
print(len(pmids))
```

**`scan` には必ず絞り込んだ query を渡してください。** 3,820万件が入っている
ため、条件なしで流すと終わりません。先に `es.count()` で件数を確かめる習慣を
つけると安全です。

---

## 8. DataFrame にする

```python
import pandas as pd

res = es.search(
    index="pubmed_articles",
    query=query,
    size=1000,
    source=["pmid", "year", "journal", "title"],
)

df = pd.DataFrame(h["_source"] for h in res["hits"]["hits"])
```

---

## 9. 文検索と記事情報をつなぐ

`pubmed_sentences` で文を引き、その PMID で `pubmed_articles` を引く、という
流れです。`search_demo/overlap_sentence.ipynb` がやっているのもこれです。

```python
res = es.search(
    index="pubmed_sentences",
    query={"match_phrase": {"sentence": "adverse event"}},
    size=100,
    source=["pmid", "sentence"],
)

pmids = list({h["_source"]["pmid"] for h in res["hits"]["hits"]})

articles = es.search(
    index="pubmed_articles",
    query={"terms": {"pmid": pmids}},
    size=len(pmids),
    source=["pmid", "year", "title"],
)
```

---

## 収録データ

| インデックス | 件数 | 粒度 |
|---|---|---|
| `pubmed_articles` | 38,197,689 | 1 記事 1 件 |
| `pubmed_sentences` | 1,000,000 | 1 文 1 件 |

`pubmed_sentences` はお試し用に先頭 100万件だけです。増やす場合は
[README.md](README.md) の `LIMIT` を参照してください。

### pubmed_articles のフィールド

| フィールド | 型 | クエリ例 |
|---|---|---|
| `pmid` | long | `{"term": {"pmid": 12345678}}` |
| `title` | text (語幹あり) | `{"match": {"title": "diabetes"}}` |
| `abstract` | text (語幹あり) | `{"match_phrase": {"abstract": "insulin resistance"}}` |
| `journal` | keyword | `{"term": {"journal": "Nature"}}` |
| `language` | keyword | `{"term": {"language": "eng"}}` |
| `year` | integer | `{"range": {"year": {"gte": 2020}}}` |
| `mesh` | keyword (複数値) | `{"term": {"mesh": "Humans"}}` |
| `publication_types` | keyword (複数値) | `{"term": {"publication_types": "Review"}}` |
| `abstract_truncated` | integer | `{"term": {"abstract_truncated": 1}}` |

### pubmed_sentences のフィールド

| フィールド | 型 | クエリ例 |
|---|---|---|
| `pmid` | long | `{"term": {"pmid": 12345678}}` |
| `sent_id` | integer | `{"term": {"sent_id": 0}}` |
| `sentence` | text (語幹あり) | `{"match_phrase": {"sentence": "adverse event"}}` |

---

## 注意

`title` と `abstract` は text 型で `.keyword` のサブフィールドを持たないため、
**並べ替えや集計には使えません。** `sort` には `year` や `pmid` を使ってください。

```python
res = es.search(index="pubmed_articles", query=query, size=10,
                sort=[{"year": "desc"}])
```
