#!/bin/bash
#SBATCH --job-name=pubmed_es_smoke
#SBATCH --partition=small-grace-o
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=1:00:00
#SBATCH --output=logs/pubmed_es_smoke_%j.out

# =====================================================
# PubMed -> Elasticsearch スモークテスト (Slurm)
#
# 計算ノード上で Elasticsearch を起動し、少量データで
# prepare_elasticsearch_parquet.py の設定・マッピング・
# action generator が実データに対して動くかを検証する。
#
# 前提:
#   1. login node で SIF をビルド済みであること
#        cd env && ./build_es.sh
#   2. .venv / env.sif / data/260420_pubmed の symlink が
#      計算ノードから解決できること
#
# 投入 (必ずリポジトリルートから):
#   cd /workspace/filesrv01/yoshikawa/260805_make_biore_ds/pubmed_handler
#   mkdir -p logs
#   sbatch env/smoke_test_slurm.sh
#
# 投入件数を変える場合:
#   sbatch --export=ALL,SMOKE_N_DOCS=1000 env/smoke_test_slurm.sh
# =====================================================

set -euo pipefail

# =====================================================
# ROOT_DIR
#
# Slurm はバッチスクリプトを計算ノードの spool へコピーして
# 実行するため、$0 からリポジトリ位置は解決できない。
# 投入ディレクトリ (SLURM_SUBMIT_DIR) を基準にする。
# =====================================================

ROOT_DIR="${PUBMED_HANDLER_ROOT:-${SLURM_SUBMIT_DIR:-}}"

if [ -z "${ROOT_DIR}" ] || [ ! -f "${ROOT_DIR}/env/run_es.sh" ]; then
    echo "[FATAL] リポジトリルートを解決できません (ROOT_DIR='${ROOT_DIR}')"
    echo "        pubmed_handler のルートから投入してください:"
    echo "          cd <path>/pubmed_handler && sbatch env/smoke_test_slurm.sh"
    echo "        別の場所から投入する場合は PUBMED_HANDLER_ROOT を指定してください。"
    exit 1
fi

source "${ROOT_DIR}/env/common.sh"

ES_SIF="${ROOT_DIR}/sif/elasticsearch.sif"
ENV_SIF="${ROOT_DIR}/env.sif"

LOG_DIR="${ROOT_DIR}/logs/${SLURM_JOB_ID}"
ES_LOG="${LOG_DIR}/elasticsearch.out"

mkdir -p "${LOG_DIR}"

# =====================================================
# 環境変数
#
# 投入スクリプトの ES_HOST デフォルトは Docker 構成用の
# "http://elasticsearch:9200" のため、Apptainer 構成では
# 必ず localhost に上書きする必要がある。
# =====================================================

export ES_HOST="http://localhost:9200"
export ES_USER="elastic"
export ES_PASSWORD=""
export DATA_DIR="${ROOT_DIR}/data"
export SMOKE_N_DOCS="${SMOKE_N_DOCS:-10000}"

echo "=== 設定 ==="
echo "  NODE         : ${SLURMD_NODENAME:-unknown}"
echo "  JOB_ID       : ${SLURM_JOB_ID}"
echo "  ROOT_DIR     : ${ROOT_DIR}"
echo "  ES_HOST      : ${ES_HOST}"
echo "  DATA_DIR     : ${DATA_DIR}"
echo "  SMOKE_N_DOCS : ${SMOKE_N_DOCS}"
echo

# =====================================================
# 事前チェック (fail-fast)
# =====================================================

if [ ! -f "${ES_SIF}" ]; then
    echo "[FATAL] ${ES_SIF} がありません。"
    echo "        login node で先にビルドしてください:"
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

# 同一ノードで別の Elasticsearch が 9200 を使っていると起動できないため、
# 起動前に確認する。
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
# setsid で独立したプロセスグループにし、終了時にその
# グループだけを停止する (他ジョブの ES を巻き込まない)。
# =====================================================

echo "[INFO] Elasticsearch 起動中... (log: ${ES_LOG})"

setsid bash "${ROOT_DIR}/env/run_es.sh" > "${ES_LOG}" 2>&1 &
ES_PID=$!

cleanup() {
    echo
    echo "[INFO] Elasticsearch 停止中 (pid=${ES_PID})"
    kill -TERM -"${ES_PID}" 2>/dev/null \
        || kill -TERM "${ES_PID}" 2>/dev/null \
        || true
    sleep 5
    # 取りこぼしはジョブ終了時に Slurm の cgroup が回収する。
}

trap cleanup EXIT

# =====================================================
# 起動待機 (最大 600 秒)
# =====================================================

echo "[INFO] Elasticsearch の起動を待機中..."

READY=0

for i in $(seq 1 60); do
    if curl -s -m 3 "${ES_HOST}/_cluster/health" | grep -q '"status"'; then
        READY=1
        echo "[INFO] Elasticsearch 起動完了 ($((i * 10)) 秒)"
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

curl -s "${ES_HOST}"
echo
echo

# =====================================================
# スモークテスト実行
# =====================================================

echo "[INFO] スモークテスト実行"
echo

apptainer exec \
    --bind /workspace \
    --env ES_HOST="${ES_HOST}" \
    --env ES_USER="${ES_USER}" \
    --env ES_PASSWORD="${ES_PASSWORD}" \
    --env DATA_DIR="${DATA_DIR}" \
    --env SMOKE_N_DOCS="${SMOKE_N_DOCS}" \
    "${ENV_SIF}" \
    bash -c "
        set -euo pipefail

        source ${ROOT_DIR}/.venv/bin/activate

        cd ${ROOT_DIR}

        python prepare_with_parquet/smoke_test_es.py
    "

echo
echo "[INFO] スモークテスト正常終了"
