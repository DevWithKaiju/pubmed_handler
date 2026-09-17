# pubmed_handler

PubMed論文データをElasticsearchに投入し、BM25全文検索を行うためのリポジトリです。

Elasticsearch は Apptainer (HPC/Slurm 環境) または Docker で起動できます。

---

## リポジトリ構成

```
pubmed_handler/
├── env/                          # Apptainer + Slurm 環境 (現行)
│   ├── build_es.sh               # elasticsearch.sif のビルド
│   ├── build_kibana.sh           # kibana.sif のビルド
│   ├── run_es.sh                 # Elasticsearch 起動
│   ├── run_kibana.sh             # Kibana 起動
│   ├── common.sh                 # 二重起動ガード
│   ├── smoke_test_slurm.sh       # 動作確認ジョブ
│   ├── index_slurm.sh            # 本番投入ジョブ
│   └── serve_slurm.sh            # ES + JupyterLab + Kibana 常駐ジョブ
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
├── USAGE_KIBANA.md               # 検索の手引き (ブラウザ)
├── USAGE_JUPYTER.md              # 検索の手引き (Python)
│
└── search_demo/                  # 検索デモ notebook
    ├── search_drugbank.ipynb
    ├── search_meddra.ipynb
    ├── search_pubchem.ipynb
    ├── search_rxnorm.ipynb
    ├── search_cell_ontology.ipynb
    └── overlap_sentence.ipynb
```

`*_slurm.sh` はいずれも **リポジトリルートから `sbatch` で投入します。**

以下は実行時に作られます (いずれも git 管理外)。

```
├── env.sif                      # symlink -> 0_ENV の Python 環境
├── .venv                        # symlink -> 0_ENV の venv
├── sif/
│   ├── elasticsearch.sif        # build_es.sh が作る
│   └── kibana.sif               # build_kibana.sh が作る
├── data/
│   ├── 260420_pubmed            # symlink -> parquet の置き場
│   ├── esdata/                  # ES のインデックス実体
│   ├── esconfig/                # SIF から取り出した ES の config
│   ├── eslogs/                  # ES のログ
│   ├── kibanaconfig/            # SIF から取り出した Kibana の config
│   └── kibanadata/              # Kibana の作業領域
└── logs/                        # ジョブのログ
```

---

## セットアップ (HPC)

Python 環境は共有の `0_ENV` から symlink で持ち込みます。`<env>` は使う
パーティションに合わせます (arm64 の `grace` 系なら `grace`)。

```bash
ln -s <0_ENV>/envs/<env>/.venv    .venv
ln -s <0_ENV>/envs/<env>/env.sif  env.sif
ln -s <0_ENV>/envs/<env>/uv.lock  uv.lock

mkdir -p data
ln -s <parquet の置き場> data/260420_pubmed

mkdir -p logs
```

### SIF のビルド (初回のみ)

**ES を動かすパーティションと同じ CPU アーキテクチャでビルドしてください。**
SIF はアーキテクチャ依存で、amd64 でビルドしたものを arm64 ノードで動かすと
起動時に落ちます。

```
FATAL: could not open image .../elasticsearch.sif:
the image's architecture (amd64) could not run on the host's (arm64)
```

`creator` 系は amd64、`grace` 系は arm64 です。パーティションを変えた場合は
`rm -rf sif/` して作り直します。

```bash
# arm64 partition: build on the target partition
sbatch env/build_es.sh
sbatch env/build_kibana.sh

# amd64: run directly on the login node
./env/build_es.sh
./env/build_kibana.sh
```

いずれの場合も出力先は `sif/` 配下に絶対パスで解決されます。既に存在する
場合は何もせず終了します。

外部ネットワーク (`docker.elastic.co`) にアクセスできる必要があります。
計算ノードから到達できない場合は、同じアーキテクチャの到達可能なノードで
ビルドして SIF を配置してください。

Kibana は任意です。`sif/kibana.sif` が無い場合、`serve_slurm.sh` は Kibana を
スキップして JupyterLab だけで起動します。Kibana と Elasticsearch のバージョンは
揃える必要があります (現在 8.13.2)。

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

#### 1. スモークテスト

少量データで「ES が起動し、parquet が読め、投入と検索ができる」ことを確認します。
本番インデックスには触れず、`smoke_test_*` の一時インデックスを作って必ず削除します。

```bash
sbatch env/smoke_test_slurm.sh

# change the number of documents
sbatch --export=ALL,SMOKE_N_DOCS=200000 env/smoke_test_slurm.sh
```

#### 2. 本番投入

**articles と sentences は分けて流してください。** 投入スクリプトは実行のたびに
インデックスを削除して作り直すため、途中で落ちると再開できません。分けておけば
片方が時間切れになってももう片方は残ります。

```bash
sbatch --export=ALL,TARGETS=articles  env/index_slurm.sh
# check that it finished, then
sbatch --export=ALL,TARGETS=sentences env/index_slurm.sh
```

進捗は 60 秒ごとにログへ出力されます (件数、docs/s、経過、残り、失敗数)。
実測スループットは約 15,000〜20,000 docs/s です (arm64、ES ヒープ 8g)。
articles の 3,820万件で 42 分でした。

`LIMIT` でインデックスあたりの件数に上限をかけられます。

```bash
sbatch --export=ALL,TARGETS=sentences,LIMIT=1000000 env/index_slurm.sh
```

件数を絞りすぎると `search_demo/*.ipynb` がヒット 0 件になり、壊れているように
見えます。オントロジーとのオーバーラップを試すなら 100万件程度は入れておくと
よいです (約 1 分)。

#### 3. 常駐サービス (ES + JupyterLab + Kibana)

```bash
sbatch env/serve_slurm.sh
tail -f logs/pubmed_es_jupyter_<jobid>.out
```

ログに SSH トンネルのコマンドと接続 URL が出ます。同一ノードで ES が動いて
いるため、notebook からは `http://localhost:9200` でそのまま繋がります。

**接続情報が表示されてから JupyterLab が実際にポートを掴むまで 1 分ほど
かかります。** その間は接続を拒否されるので、待ってから再読み込みしてください。

消し忘れ防止として、使われなくなると自動終了します
(既定: 無操作カーネルを 30 分で片付け、その状態が 60 分続いたら終了)。

```bash
# shorten the timeouts
sbatch --export=ALL,KERNEL_CULL_TIMEOUT=600,IDLE_TIMEOUT=900 env/serve_slurm.sh

# extend them (useful when working only in Kibana)
sbatch --export=ALL,KERNEL_CULL_TIMEOUT=21600,IDLE_TIMEOUT=21600 env/serve_slurm.sh
```

**自動終了の判定に使われるのは Jupyter のカーネル/ターミナルの活動だけです。**
Kibana だけを使っていると無操作とみなされ、作業中でもジョブごと終了します。

### Docker (ローカル開発)

```bash
cd previous_env
docker compose up -d
```

---

## 重要な制約

### 同時に 1 つの Elasticsearch しか動かせない

`data/esdata` は NFS 上にあるため、**別ノードで 2 つ目の ES が起動すると
同じデータディレクトリを同時に開いてインデックスが壊れます。**

これを防いでいるのは ES の `node.lock` だけですが、NFS 上のファイルロックは
確実ではありません (ES が NFS を非推奨とする理由)。そのため各スクリプトは
`common.sh` の `check_no_other_es_job()` で `squeue` を確認し、
`pubmed_es_` で始まるジョブが他にあれば起動を拒否します。

`squeue` 自体が失敗した場合も「重複なし」とはみなさず中止します。
投入ジョブと `serve_slurm.sh` も同時には実行できません。

### login node からは ES に繋がらない

ES は compute node 上で `127.0.0.1:9200` のみを待ち受けます。login node で
`curl http://localhost:9200` を叩いても繋がりません。notebook や Kibana から
使う場合は `serve_slurm.sh` を使ってください (ES と同じノードに乗ります)。

`network.host` を `0.0.0.0` にすれば他ノードからも見えますが、
`xpack.security.enabled: false` で運用しているため、共有クラスタでは
**誰でもインデックスを削除できる状態になります**。採用していません。

---

## Apptainer 固有の注意点

Docker 用の設定をそのまま持ってくると動きません。`run_es.sh` と
`run_kibana.sh` は以下に対処済みです。

### 1. コンテナが読み取り専用

Elasticsearch は起動時に `config/` へ keystore を書き込みますが、Apptainer の
コンテナには Docker のような書き込み可能レイヤーが無く、以下で失敗します。

```
java.nio.file.FileSystemException:
  /usr/share/elasticsearch/config/elasticsearch.keystore.tmp: Read-only file system
```

対策として、SIF から `config/` を `data/esconfig/` へ取り出して bind しています
(初回のみ。`.prepared` で管理)。`logs/` も書き込み先が必要なので同様に bind します。
Kibana も同じ理由で `data/kibanaconfig/` と `data/kibanadata/` を bind します。

### 2. 設定名にドットが含まれる

`--env discovery.type=single-node` のような指定は、シェルの変数名として不正な
ため Apptainer の env 注入時に落とされます (Docker はドット付きの環境変数名を
許すので compose 版では動いていました)。

```
source: /.inject-apptainer-env.sh:9:11: invalid var name
```

対策として、これらは環境変数ではなく `data/esconfig/elasticsearch.yml` に書きます。

```yaml
cluster.name: pubmed-es
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
```

イメージ付属の `elasticsearch.yml` には `network.host` 等が含まれるため、
追記ではなく**置き換え**ています (YAML のキー重複を避けるため)。
`data/kibanaconfig/kibana.yml` も同じ理由で毎回書き出します (ポートが
起動のたびに変わるため)。

`ES_JAVA_OPTS` はドットを含まないので環境変数のままで構いません。ヒープサイズは
`ES_HEAP` で上書きできます (既定 `4g`、常駐・本番投入は `8g`)。

---

## インデックス作成スクリプトを直接実行する場合

Slurm ジョブ経由なら環境変数は自動で設定されます。手で動かす場合のみ以下が必要です。

```bash
export ES_HOST=http://localhost:9200
export ES_USER=elastic
export ES_PASSWORD=          # セキュリティ無効の場合は空
export DATA_DIR=/path/to/data
export TARGETS=all           # all | articles | sentences | labels (カンマ区切り可)
export LIMIT=0               # インデックスあたりの投入件数の上限 (0 = 無制限)

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

## 検索のしかた

フィールドの型ごとの書き方、絞り込み、集計、大量取得の方法は使い方の手引きに
まとめてあります。

- [USAGE_KIBANA.md](USAGE_KIBANA.md) — ブラウザ (KQL)
- [USAGE_JUPYTER.md](USAGE_JUPYTER.md) — Python

---

## トラブルシュート

### ES が起動しない

```bash
tail -50 logs/<jobid>/elasticsearch.out
```

### Kibana が起動しない

```bash
tail -50 logs/<jobid>/kibana.out
```

Kibana が起動しなくてもジョブは落とさず、JupyterLab のみで続行します。

### `node.lock` が残って起動しない

ジョブが強制終了された場合に起こりえます。他に ES ジョブが動いていないことを
`squeue -u $USER` で確認してから削除します。

```bash
rm data/esdata/node.lock
```

### config を作り直したい

```bash
rm -rf data/esconfig      # Elasticsearch
rm -rf data/kibanaconfig  # Kibana
```

次回の起動時に SIF から取り出し直されます。

### アーキテクチャが合わずに起動しない

```bash
rm -rf sif/
sbatch env/build_es.sh
sbatch env/build_kibana.sh
```

### `Permission denied` で起動しない

スクリプトに実行権限がありません。

```bash
chmod +x env/*.sh
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
