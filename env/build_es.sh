#!/bin/bash

set -e

# 出力先をスクリプト位置基準で解決する (run_es.sh と同じ)。
# 相対パスだと呼び出し元の CWD によってリポジトリ外へ出力されてしまう。
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

SIF_DIR=${ROOT_DIR}/sif
ES_SIF=${SIF_DIR}/elasticsearch.sif

if [ -f "${ES_SIF}" ]; then
    echo "[INFO] ${ES_SIF} は既に存在します。再ビルドする場合は削除してください。"
    exit 0
fi

mkdir -p "${SIF_DIR}"

echo "[INFO] Building ${ES_SIF} ..."

apptainer build \
  "${ES_SIF}" \
  docker://docker.elastic.co/elasticsearch/elasticsearch:8.13.2
