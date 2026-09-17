'''
 # @ Description:
 #   PubMed parquet -> Elasticsearch のスモークテスト
 #
 #   本番投入 (prepare_elasticsearch_parquet.py) はデータ規模が大きく
 #   (articles 約3,820万行 / sentences 約8,690万行)、動作確認のために
 #   フル実行するのは現実的ではない。本スクリプトは少量データで以下を検証する:
 #
 #     1. Elasticsearch への接続
 #     2. parquet のスキーマが投入スクリプトの期待と一致するか
 #     3. インデックス作成 (porter_stem マッピングが有効か)
 #     4. bulk 投入
 #     5. 検索と porter_stem の動作
 #
 #   設定値・マッピング・action generator はすべて
 #   prepare_elasticsearch_parquet.py から import する。
 #   本番と同一の定義を検証しないと動作確認の意味がないため。
 #
 #   本番インデックスには触れない。一時インデックス (smoke_test_*) を
 #   作成し、成否に関わらず終了時に削除する。
 #
 #   環境変数:
 #     SMOKE_N_DOCS : 各インデックスへ投入する件数 (デフォルト 10000)
 #     その他 (ES_HOST / DATA_DIR 等) は投入スクリプトと共通
'''

import os
from itertools import islice

import pyarrow.parquet as pq
from elasticsearch import helpers
from prepare_elasticsearch_parquet import (
    ARTICLE_PARQUET,
    ES_HOST,
    MAPPING_ARTICLE,
    MAPPING_SENTENCE,
    SENTENCE_PARQUET,
    article_actions,
    make_es,
    sentence_actions,
)

# =========================================================
# Config
# =========================================================

N_DOCS = int(os.environ.get("SMOKE_N_DOCS", "10000"))

INDEX_ARTICLE  = "smoke_test_pubmed_articles"
INDEX_SENTENCE = "smoke_test_pubmed_sentences"

# 投入スクリプトの action generator が参照する parquet のカラム。
# ここが実データと食い違うと本番投入が KeyError で落ちるため、
# 少量投入の前にスキーマだけ先に検証する。
#
# ES のフィールド名とは一致しない点に注意
#   abstract_lang -> language / pub_type -> publication_types
REQUIRED_COLUMNS_ARTICLE = [
    "pmid", "title", "abstract", "journal", "abstract_lang",
    "year", "mesh", "pub_type", "abstract_truncated",
]

REQUIRED_COLUMNS_SENTENCE = ["pmid", "sent_id", "sentence"]


# =========================================================
# Checks
# =========================================================

def check_schema(label, parquet_path, required_columns):
    '''
    parquet のカラムが投入スクリプトの期待と一致するか検証する。

    不足があっても例外にせず、不足カラムのリストを返す。
    全対象のスキーマをまとめて検証し、問題を一度に報告するため
    (1件ずつ落ちると往復が増える)。
    '''

    if not parquet_path.exists():
        raise FileNotFoundError(f"{label}: {parquet_path} が存在しません")

    pf = pq.ParquetFile(parquet_path)
    schema = pf.schema_arrow
    columns = set(schema.names)
    missing = [c for c in required_columns if c not in columns]

    print(f"  rows     : {pf.metadata.num_rows:,}")
    print(f"  columns  : {sorted(columns)}")

    # 型の食い違いは ES 側の mapping エラーになるため、必要カラムの型も出す
    types = ", ".join(
        f"{c}:{schema.field(c).type}" for c in required_columns if c in columns
    )
    print(f"  types    : {types}")

    if missing:
        print(f"  schema   : NG (不足カラム -> {missing})")
    else:
        print(f"  schema   : OK ({len(required_columns)} カラムすべて存在)")

    return missing


def index_sample(label, es, index_name, mapping, actions_iter):
    '''一時インデックスを作成し、先頭 N_DOCS 件だけ投入する。'''

    if es.indices.exists(index=index_name):
        es.indices.delete(index=index_name)

    es.indices.create(index=index_name, body=mapping)
    print(f"  index    : '{index_name}' 作成 (mapping 受理)")

    success, failed = 0, 0
    first_error = None

    # 本番と同じ parallel_bulk を使う。islice で先頭 N_DOCS 件に制限する
    # (iter_batches は遅延読み込みのため parquet 全体は読まれない)。
    for ok, info in helpers.parallel_bulk(
        es,
        islice(actions_iter, N_DOCS),
        chunk_size=1_000,
        thread_count=4,
        raise_on_error=False,
    ):
        if ok:
            success += 1
        else:
            failed += 1
            if first_error is None:
                first_error = info

    es.indices.refresh(index=index_name)
    count = es.count(index=index_name)["count"]

    print(f"  bulk     : indexed={success:,} failed={failed:,} count={count:,}")

    if first_error is not None:
        # 本番スクリプトは失敗内容を捨てるため、ここで最初の1件を出しておく
        print(f"  [ERROR] 最初の失敗内容: {first_error}")

    if failed:
        raise RuntimeError(f"{label}: bulk 投入に {failed} 件の失敗があります")

    if count == 0:
        raise RuntimeError(f"{label}: 投入後の件数が 0 です")


def check_search(label, es, index_name, text_field):
    '''投入した文書が実際に検索でヒットするか確認する。'''

    res = es.search(index=index_name, query={"match_all": {}}, size=1)
    hits = res["hits"]["hits"]

    if not hits:
        raise RuntimeError(f"{label}: match_all で1件もヒットしません")

    sample = str(hits[0]["_source"].get(text_field, ""))
    print(f"  search   : OK (例: {sample[:70]}...)")


def check_keyword_split(label, es, index_name, field):
    '''
    "A|B|C" 形式の文字列を分割して配列で投入できているか確認する。

    分割せずに keyword へ入れると全体が1トークンになり、
    個別の語での term 検索がヒットしなくなる。
    '''

    res = es.search(index=index_name, query={"match_all": {}}, size=50)

    sample = None

    for hit in res["hits"]["hits"]:
        values = hit["_source"].get(field)

        if not isinstance(values, list):
            raise TypeError(
                f"{label}: {field} が配列ではありません -> {values!r}"
            )

        if values and sample is None:
            sample = values[0]

    if sample is None:
        print(f"  {field:9}: 全て空のため未検証")
        return

    total = es.search(
        index=index_name,
        query={"term": {field: sample}},
        size=0,
    )["hits"]["total"]["value"]

    if total == 0:
        raise RuntimeError(
            f"{label}: {field}='{sample}' の term 検索が0件 (未分割の可能性)"
        )

    print(f"  {field:9}: OK (term='{sample}' -> {total} 件)")


def check_stemming(label, es, index_name):
    '''porter_stem アナライザーが実際に効いているか analyze API で確認する。'''

    res = es.indices.analyze(
        index=index_name,
        analyzer="english_stemmed",
        text="The patients were running studies",
    )
    tokens = [t["token"] for t in res["tokens"]]

    # porter_stem が効いていれば
    #   patients -> patient / running -> run / studies -> studi
    expected = {"patient", "run", "studi"}
    missing = expected - set(tokens)

    print(f"  analyze  : {tokens}")

    if missing:
        raise RuntimeError(
            f"{label}: porter_stem が効いていません (不足: {sorted(missing)})"
        )

    print("  stemming : OK (porter_stem 有効)")


# =========================================================
# Main
# =========================================================

def main():
    print("=" * 62)
    print("PubMed parquet -> Elasticsearch スモークテスト")
    print("=" * 62)
    print(f"ES_HOST      : {ES_HOST}")
    print(f"SMOKE_N_DOCS : {N_DOCS:,}")
    print()

    es = make_es()
    print(f"接続OK: Elasticsearch {es.info()['version']['number']}\n")

    # 末尾は "A|B|C" を分割して配列で入れるフィールド
    targets = [
        ("ARTICLES", INDEX_ARTICLE, MAPPING_ARTICLE, ARTICLE_PARQUET,
         REQUIRED_COLUMNS_ARTICLE, article_actions, "title",
         ("mesh", "publication_types")),
        ("SENTENCES", INDEX_SENTENCE, MAPPING_SENTENCE, SENTENCE_PARQUET,
         REQUIRED_COLUMNS_SENTENCE, sentence_actions, "sentence",
         ()),
    ]

    # --- 1. 先に全対象のスキーマを検証する ---------------------------
    #
    # ES への投入は時間がかかるため、カラム名の食い違いのような
    # 静的に分かる問題は全部先に洗い出してから投入へ進む。

    schema_errors = {}

    for label, _, _, path, required, _, _, _ in targets:
        print(f"--- {label}: {path.name} ---")
        missing = check_schema(label, path, required)
        if missing:
            schema_errors[label] = missing
        print()

    if schema_errors:
        raise KeyError(f"スキーマ不一致: {schema_errors}")

    # --- 2. 少量投入して検索まで確認する -----------------------------

    created = []

    try:
        for label, index_name, mapping, path, _, gen_fn, text_field, split_fields in targets:
            print(f"--- {label}: 投入 ---")

            created.append(index_name)
            index_sample(label, es, index_name, mapping, gen_fn(path, index_name))

            check_search(label, es, index_name, text_field)

            for field in split_fields:
                check_keyword_split(label, es, index_name, field)

            check_stemming(label, es, index_name)
            print()

    finally:
        for index_name in created:
            if es.indices.exists(index=index_name):
                es.indices.delete(index=index_name)
                print(f"cleanup  : '{index_name}' 削除")

    print()
    print("=" * 62)
    print("すべて成功しました。本番投入に進めます。")
    print("=" * 62)


if __name__ == "__main__":
    main()
