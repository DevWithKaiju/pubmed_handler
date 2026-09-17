# Elasticsearch + Apptainer 環境 (Slurm/HPC)

Apptainer 上で Elasticsearch を動かし、Python から接続するための環境。

---

## スクリプト一覧

| ファイル | 役割 |
|---|---|
| `build_es.sh` | `sif/elasticsearch.sif` をビルドする (初回のみ) |
| `run_es.sh` | Elasticsearch を起動する (フォアグラウンド) |
| `common.sh` | ジョブ間で共有するヘルパー (二重起動ガード) |
| `smoke_test_slurm.sh` | 少量データで一通り動くかを検証する |
| `index_slurm.sh` | 本番投入 |
| `serve_slurm.sh` | Elasticsearch + JupyterLab を常駐させる |

`*_slurm.sh` はいずれも **リポジトリルートから `sbatch` で投入する**。

---

## 前提

### ディレクトリ構成

```text
pubmed_handler/
├── env.sif                      # symlink -> 0_ENV の Python 環境
├── .venv                        # symlink -> 0_ENV の venv
├── sif/
│   └── elasticsearch.sif        # build_es.sh が作る
├── data/
│   ├── 260420_pubmed            # symlink -> parquet の置き場
│   ├── esdata/                  # ES のインデックス実体
│   ├── esconfig/                # SIF から取り出した ES の config
│   └── eslogs/                  # ES のログ
└── logs/                        # ジョブのログ
```

`data/` は `.gitignore` 済み。`logs/` は投入前に `mkdir -p logs` が必要。

### SIF のビルド (初回のみ)

```bash
./env/build_es.sh
```

出力先はスクリプト位置基準で `sif/elasticsearch.sif` に解決されるため、
どこから呼んでもよい。既に存在する場合は何もせず終了する。

外部ネットワーク (`docker.elastic.co`) にアクセスできる必要がある。
login node で実行すること (計算ノードから到達できるとは限らないため)。

---

## 使い方

### 1. スモークテスト

少量データで「ES が起動し、parquet が読め、投入と検索ができる」ことを確認する。

```bash
cd <path>/pubmed_handler
mkdir -p logs

sbatch env/smoke_test_slurm.sh

# 件数を変える場合
sbatch --export=ALL,SMOKE_N_DOCS=200000 env/smoke_test_slurm.sh
```

本番インデックスには触れず、`smoke_test_*` の一時インデックスを作って必ず削除する。

### 2. 本番投入

**articles と sentences は分けて流すこと。** 投入スクリプトは実行のたびに
インデックスを削除して作り直すため、途中で落ちると再開できない。分けておけば
片方が時間切れになってももう片方は残る。

```bash
sbatch --export=ALL,TARGETS=articles  env/index_slurm.sh
# 完了を確認してから
sbatch --export=ALL,TARGETS=sentences env/index_slurm.sh
```

進捗は 60 秒ごとにログへ出力される (件数、docs/s、経過、残り、失敗数)。

### 3. 常駐サービス (ES + JupyterLab)

```bash
sbatch env/serve_slurm.sh
tail -f logs/pubmed_es_jupyter_<jobid>.out
```

ログに SSH トンネルのコマンドと接続 URL が出る。同一ノードで ES が動いている
ため、notebook からは `http://localhost:9200` でそのまま繋がる。

消し忘れ防止として、使われなくなると自動終了する
(既定: 無操作カーネルを 30 分で片付け、その状態が 60 分続いたら終了)。

```bash
# タイムアウトを短くする場合
sbatch --export=ALL,KERNEL_CULL_TIMEOUT=600,IDLE_TIMEOUT=900 env/serve_slurm.sh
```

---

## 重要な制約

### 同時に 1 つの Elasticsearch しか動かせない

`data/esdata` は NFS 上にあるため、**別ノードで 2 つ目の ES が起動すると
同じデータディレクトリを同時に開いてインデックスが壊れる。**

これを防いでいるのは ES の `node.lock` だけだが、NFS 上のファイルロックは
確実ではない (ES が NFS を非推奨とする理由)。そのため各スクリプトは
`common.sh` の `check_no_other_es_job()` で `squeue` を確認し、
`pubmed_es_` で始まるジョブが他にあれば起動を拒否する。

`squeue` 自体が失敗した場合も「重複なし」とはみなさず中止する。

### login node からは ES に繋がらない

ES は compute node 上で `127.0.0.1:9200` のみを待ち受ける。login node で
`curl http://localhost:9200` を叩いても繋がらない。notebook から使う場合は
`serve_slurm.sh` を使うこと (ES と Jupyter が同じノードに乗る)。

`network.host` を `0.0.0.0` にすれば他ノードからも見えるが、
`xpack.security.enabled: false` で運用しているため、共有クラスタでは
**誰でもインデックスを削除できる状態になる**。採用していない。

---

## Apptainer 固有の注意点

Docker 用の設定をそのまま持ってくると動かない。`run_es.sh` は以下に対処済み。

### 1. コンテナが読み取り専用

Elasticsearch は起動時に `config/` へ keystore を書き込むが、Apptainer の
コンテナには Docker のような書き込み可能レイヤーが無く、以下で失敗する。

```text
java.nio.file.FileSystemException:
  /usr/share/elasticsearch/config/elasticsearch.keystore.tmp: Read-only file system
```

対策として、SIF から `config/` を `data/esconfig/` へ取り出して bind している
(初回のみ。`.prepared` で管理)。`logs/` も書き込み先が必要なので同様に bind する。

### 2. 設定名にドットが含まれる

`--env discovery.type=single-node` のような指定は、シェルの変数名として不正な
ため Apptainer の env 注入時に落とされる (Docker はドット付きの環境変数名を
許すので compose 版では動いていた)。

```text
source: /.inject-apptainer-env.sh:9:11: invalid var name
```

対策として、これらは環境変数ではなく `data/esconfig/elasticsearch.yml` に書く。

```yaml
cluster.name: pubmed-es
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
```

イメージ付属の `elasticsearch.yml` には `network.host` 等が含まれるため、
追記ではなく**置き換え**ている (YAML のキー重複を避けるため)。

`ES_JAVA_OPTS` はドットを含まないので環境変数のままでよい。ヒープサイズは
`ES_HEAP` で上書きできる (既定 `4g`、常駐・本番投入は `8g`)。

---

## トラブルシュート

### ES が起動しない

```bash
tail -50 logs/<jobid>/elasticsearch.out
```

### `node.lock` が残って起動しない

ジョブが強制終了された場合に起こりうる。他に ES ジョブが動いていないことを
`squeue -u $USER` で確認してから削除する。

```bash
rm data/esdata/node.lock
```

### config を作り直したい

```bash
rm -rf data/esconfig
```

次回の `run_es.sh` で SIF から取り出し直される。

### `Permission denied` で起動しない

スクリプトに実行権限が無い。

```bash
chmod +x env/*.sh
```
