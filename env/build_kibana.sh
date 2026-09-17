#!/bin/bash
#SBATCH --job-name=build_kibana
#SBATCH --partition=x-large-grace-o
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=4:00:00
#SBATCH --output=logs/build_kibana_%j.out

set -e

# 出力先を絶対パスで解決する。
# 相対パスだと呼び出し元の CWD によってリポジトリ外へ出力されてしまう。
#
# sbatch 経由の場合、Slurm はバッチスクリプトを計算ノードの spool へ
# コピーして実行するため $0 からリポジトリ位置を解決できない。
# 直接実行 (login node) の場合は $0 から解決する。
if [ -n "${SLURM_JOB_ID:-}" ]; then
    ROOT_DIR="${PUBMED_HANDLER_ROOT:-${SLURM_SUBMIT_DIR:-}}"
else
    ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
fi

if [ -z "${ROOT_DIR}" ] || [ ! -f "${ROOT_DIR}/env/run_es.sh" ]; then
    echo "[FATAL] リポジトリルートを解決できません (ROOT_DIR='${ROOT_DIR}')"
    echo "        pubmed_handler のルートから投入してください:"
    echo "          cd <path>/pubmed_handler && sbatch env/build_kibana.sh"
    exit 1
fi

SIF_DIR=${ROOT_DIR}/sif
KIBANA_SIF=${SIF_DIR}/kibana.sif

# Kibana と Elasticsearch のバージョンは必ず揃える。
# ずれると Kibana が起動時に接続を拒否する。
KIBANA_VERSION=8.13.2

if [ -f "${KIBANA_SIF}" ]; then
    echo "[INFO] ${KIBANA_SIF} は既に存在します。再ビルドする場合は削除してください。"
    exit 0
fi

mkdir -p "${SIF_DIR}"

echo "[INFO] Building ${KIBANA_SIF} (${KIBANA_VERSION}) ..."

apptainer build \
  "${KIBANA_SIF}" \
  docker://docker.elastic.co/kibana/kibana:${KIBANA_VERSION}
