# Kibana で PubMed を検索する

ブラウザから GUI で検索するための手順です。  
コードから使いたい場合は [USAGE_JUPYTER.md](USAGE_JUPYTER.md) を参照してください。

---

## 1. 起動する

Elasticsearch は常駐していません。**使うたびにジョブを投げて立ち上げます。**

```bash
cd /workspace/filesrv01/yoshikawa/260805_make_biore_ds/pubmed_handler
sbatch env/serve_slurm.sh
tail -f logs/pubmed_es_jupyter_<jobid>.out
```

ログに SSH トンネルのコマンドと接続 URL が出ます。**ポートは毎回変わる**ので、
必ずログを見てください。

```bash
# run this in ANOTHER terminal on the login node, and keep it open
ssh -N -L <jupyter_port>:localhost:<jupyter_port> -L <kibana_port>:localhost:<kibana_port> -p 49152 <node>
```

トンネルを張ったまま、ログに出た Kibana の URL をブラウザで開きます。

```text
http://localhost:<kibana_port>/app/discover
```

起動直後は接続を拒否されることがあります。サービスが立ち上がるまで
30 秒ほど待ってから再読み込みしてください。

終了するときは `scancel <jobid>` です。**使い終わったら必ず落としてください。**
共有クラスタのノードを占有し続けることになります。

---

## 2. data view を作る (初回のみ)

Kibana はインデックスをそのままでは表示しません。最初に data view を作ります。

`Stack Management` > `Data Views` > `Create data view`

| 項目 | 入力 |
|---|---|
| Name | `pubmed_articles` |
| Index pattern | `pubmed_articles` |
| Timestamp field | `I don't want to use the time filter` |

`pubmed_sentences` も同様に作ります。

**Timestamp field は必ず「使わない」を選んでください。** このデータに時刻
フィールドはありません。選んでしまうと 1 件も表示されなくなります。

一度作れば Elasticsearch 側に保存されるので、次回以降は不要です。他の人が
起動した場合も同じものが見えます。

---

## 3. 表示を整える

初期状態では全フィールドが 1 列に詰め込まれて表示され、非常に読みにくいです。
**左のフィールド一覧から、必要なものを列として追加してください。**
フィールド名にマウスを乗せると出る `⊕` を押すだけです。

`pubmed_articles` なら、この並びが実用的です。

```text
year  →  journal  →  title
```

---

## 4. 検索する

上部の検索窓は KQL (Kibana Query Language) です。空欄のまま Enter を押せば
全件が表示されます。

```text
abstract : "insulin resistance"
title : diabetes and year >= 2020
mesh : "Humans" and abstract : cancer
journal : "Nature"
publication_types : "Review"
not mesh : "Animals" and abstract : "drug metabolism"
```

`and` / `or` / `not`、範囲指定 (`year >= 2020`)、ワイルドカード
(`journal : Nature*`) が使えます。

---

## 5. ハマりどころ

### keyword フィールドは完全一致

`mesh`・`journal`・`publication_types`・`language` は完全一致です。

```text
mesh : "Humans"     ← 当たる
mesh : Human        ← 当たらない
```

**正確な値がわからないときは、左のフィールド一覧で `mesh` をクリックしてください。**
出現頻度の上位 5 件が表示されるので、そこからコピーするのが確実です。
Kibana を使う一番の利点がこれです。

### title と abstract は語幹検索

porter_stem を通してあるので、`running` で `run` や `runs` にも当たります。

引用符で囲まないと単語ごとの OR 検索になります。フレーズとして扱いたいときは
囲んでください。

```text
abstract : "insulin resistance"    ← フレーズ
abstract : insulin resistance      ← insulin または resistance
```

### title と abstract では並べ替え・集計ができない

text 型に `.keyword` のサブフィールドを用意していないためです。
並べ替えには `year` や `pmid` を使ってください。

### 時間範囲ピッカーが出ない

data view を「時刻フィールドなし」で作っているためで、正常です。
常に全期間が対象になります。

---

## 6. 文単位で検索する

左上の data view のプルダウンで `pubmed_sentences` に切り替えます。
フィールドは `pmid`・`sent_id`・`sentence` の 3 つだけです。

```text
sentence : "adverse event"
```

`pubmed_articles` は全件 (3,820万件) 入っていますが、`pubmed_sentences` は
お試し用に先頭 100万件だけです。ヒット数が物足りない場合は
[README.md](README.md) の `LIMIT` を参照して入れ直してください。

---

## 7. 検索を保存する

右上の `Save` で、検索条件と列の構成をまとめて保存できます。
保存先は Elasticsearch なので、**他の人が起動しても同じものが見えます。**

よく使う検索を保存しておくと、次回は `Open` から選ぶだけで済みます。

---

## 収録データ

| インデックス | 件数 | 粒度 |
|---|---|---|
| `pubmed_articles` | 38,197,689 | 1 記事 1 件 |
| `pubmed_sentences` | 1,000,000 | 1 文 1 件 |

### pubmed_articles のフィールド

| フィールド | 型 | 検索の書き方 |
|---|---|---|
| `pmid` | long | `pmid : 12345678` |
| `title` | text (語幹あり) | `title : diabetes` |
| `abstract` | text (語幹あり) | `abstract : "insulin resistance"` |
| `journal` | keyword | `journal : "Nature"` |
| `language` | keyword | `language : "eng"` |
| `year` | integer | `year >= 2020` |
| `mesh` | keyword (複数値) | `mesh : "Humans"` |
| `publication_types` | keyword (複数値) | `publication_types : "Review"` |
| `abstract_truncated` | integer | `abstract_truncated : 1` |

### pubmed_sentences のフィールド

| フィールド | 型 | 検索の書き方 |
|---|---|---|
| `pmid` | long | `pmid : 12345678` |
| `sent_id` | integer | `sent_id : 0` |
| `sentence` | text (語幹あり) | `sentence : "adverse event"` |
