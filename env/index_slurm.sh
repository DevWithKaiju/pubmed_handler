#!/bin/bash
#SBATCH --job-name=pubmed_es_index
#SBATCH --partition=x-large-grace-o
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=24:00:00
#SBATCH --output=logs/pubmed_es_index_%j.out

# =====================================================
# PubMed parquet -> Elasticsearch 本番投入 (Slurm)
#
# 計算ノード上で Elasticsearch を起動し、
# prepare_elasticsearch_parquet.py でインデックスを作る。
# 投入が終わると ES を停止してジョブも終了する。
#
# 件数の目安:
#   articles  : 38,201,553 件
#   sentences : 80,509,187 件
#   labels    : parquet が無ければ自動でスキップ
#
# 投入スクリプトは実行のたびにインデックスを削除して
# 作り直すため、途中で落ちると再開できない。
# TARGETS でインデックス単位にジョブを分けられるので、
# articles と sentences は分けて流すことを推奨する。
#
# 投入 (必ずリポジトリルートから):
#   cd /workspace/filesrv01/yoshikawa/260805_make_biore_ds/pubmed_handler
#   mkdir -p logs
#
#   # 1本目: articles だけ
#   sbatch --export=ALL,TARGETS=articles env/index_slurm.sh
#
#   # 完了を確認してから 2本目: sentences だけ
#   sbatch --export=ALL,TARGETS=sentences env/index_slurm.sh
#
# 進捗:
#   tail -f logs/pubmed_es_index_<jobid>.out
# =====================================================

set -euo pipefail

# =====================================================
# ROOT_DIR
#
# Slurm はバッチスクリプトを計算ノードの spool へコピーして
# 実行するため、$0 からリポジトリ位置は解決できない。
# =====================================================

ROOT_DIR="${PUBMED_HANDLER_ROOT:-${SLURM_SUBMIT_DIR:-}}"

if [ -z "${ROOT_DIR}" ] || [ ! -f "${ROOT_DIR}/env/run_es.sh" ]; then
    echo "[FATAL] リポジトリルートを解決できません (ROOT_DIR='${ROOT_DIR}')"
    echo "        pubmed_handler のルートから投入してください:"
    echo "          cd <path>/pubmed_handler && sbatch env/index_slurm.sh"
    exit 1
fi

source "${ROOT_DIR}/env/common.sh"

ES_SIF="${ROOT_DIR}/sif/elasticsearch.sif"
ENV_SIF="${ROOT_DIR}/env.sif"

LOG_DIR="${ROOT_DIR}/logs/${SLURM_JOB_ID}"
ES_LOG="${LOG_DIR}/elasticsearch.out"

mkdir -p "${LOG_DIR}"

# 投入スクリプトの ES_HOST デフォルトは Docker 構成用のため上書きする
export ES_HOST="http://localhost:9200"
export ES_USER="elastic"
export ES_PASSWORD=""
export DATA_DIR="${ROOT_DIR}/data"
export TARGETS="${TARGETS:-all}"

# インデックスあたりの投入件数の上限 (0 = 無制限)。
# お試し環境を作る場合に使う:
#   sbatch --export=ALL,TARGETS=sentences,LIMIT=1000000 env/index_slurm.sh
export LIMIT="${LIMIT:-0}"

# 1億件規模の投入ではセグメントマージが重いため厚めに取る
export ES_HEAP="${ES_HEAP:-8g}"

echo "=== 設定 ==="
echo "  NODE     : ${SLURMD_NODENAME:-unknown}"
echo "  JOB_ID   : ${SLURM_JOB_ID}"
echo "  ROOT_DIR : ${ROOT_DIR}"
echo "  DATA_DIR : ${DATA_DIR}"
echo "  TARGETS  : ${TARGETS}"
echo "  LIMIT    : ${LIMIT} (0 = 無制限)"
echo "  ES_HEAP  : ${ES_HEAP}"
echo "  開始     : $(date --iso-8601=seconds)"
echo

# =====================================================
# 事前チェック (fail-fast)
# =====================================================

if [ ! -f "${ES_SIF}" ]; then
    echo "[FATAL] ${ES_SIF} がありません。"
    echo "          cd ${ROOT_DIR}/env && ./build_es.sh"
    exit 1
fi

if [ ! -e "${ENV_SIF}" ]; then
    echo "[FATAL] ${ENV_SIF} が解決できません (symlink 切れの可能性)"
    exit 1
fi

if [ ! -e "${DATA_DIR}/260420_pubmed" ]; then
    echo "[FATAL] ${DATA_DIR}/260420_pubmed が解決できません (symlink 切れの可能性)"
    exit 1
fi

if curl -s -m 3 "${ES_HOST}" > /dev/null 2>&1; then
    echo "[FATAL] ${ES_HOST} は既に使用中です。"
    echo "        同一ノードで別の Elasticsearch が動作している可能性があります。"
    exit 1
fi

# ノードを跨いだ二重起動 (NFS 上の esdata を同時に開く) を防ぐ
check_no_other_es_job

echo "[INFO] 事前チェック OK"
echo

# =====================================================
# Elasticsearch 起動
#
# Python 側も apptainer で動かすため、ES はネイティブ側で
# 起動して apptainer のネストを避ける。
# =====================================================

echo "[INFO] Elasticsearch 起動中... (heap=${ES_HEAP}, log: ${ES_LOG})"

setsid bash "${ROOT_DIR}/env/run_es.sh" > "${ES_LOG}" 2>&1 &
ES_PID=$!

cleanup() {
    echo
    echo "[INFO] Elasticsearch 停止中 (pid=${ES_PID})"
    kill -TERM -"${ES_PID}" 2>/dev/null \
        || kill -TERM "${ES_PID}" 2>/dev/null \
        || true
    sleep 10
}

trap cleanup EXIT

echo "[INFO] Elasticsearch の起動を待機中..."

READY=0

for i in $(seq 1 60); do
    if curl -s -m 3 "${ES_HOST}/_cluster/health" | grep -q '"status"'; then
        READY=1
        echo "[INFO] Elasticsearch 起動完了"
        break
    fi
    sleep 10
done

if [ "${READY}" -ne 1 ]; then
    echo "[FATAL] Elasticsearch が 600 秒以内に起動しませんでした"
    echo "----- ${ES_LOG} (末尾 50 行) -----"
    tail -n 50 "${ES_LOG}" || true
    exit 1
fi

echo

# =====================================================
# 投入
# =====================================================

echo "[INFO] インデックス投入開始 (TARGETS=${TARGETS})"
echo

apptainer exec \
    --bind /workspace \
    --env ES_HOST="${ES_HOST}" \
    --env ES_USER="${ES_USER}" \
    --env ES_PASSWORD="${ES_PASSWORD}" \
    --env DATA_DIR="${DATA_DIR}" \
    --env TARGETS="${TARGETS}" \
    --env LIMIT="${LIMIT}" \
    "${ENV_SIF}" \
    bash -c "
        set -euo pipefail

        source ${ROOT_DIR}/.venv/bin/activate

        cd ${ROOT_DIR}

        python -u prepare_with_parquet/prepare_elasticsearch_parquet.py
    "

echo
echo "[INFO] 投入完了"

# =====================================================
# 最終確認
#
# ES を止める前にインデックスの状態を記録しておく。
# =====================================================

echo
echo "=== インデックスの状態 ==="
curl -s "${ES_HOST}/_cat/indices/pubmed_*?v&h=index,docs.count,store.size" || true

echo
echo "  終了 : $(date --iso-8601=seconds)"
