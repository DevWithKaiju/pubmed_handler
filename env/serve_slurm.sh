#!/bin/bash
#SBATCH --job-name=pubmed_es_jupyter
#SBATCH --partition=x-large-creator-o
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=24:00:00
#SBATCH --output=logs/pubmed_es_jupyter_%j.out

# =====================================================
# Elasticsearch + JupyterLab 常駐サービス (Slurm)
#
# 同一 compute node 上で Elasticsearch と JupyterLab を動かす。
# notebook からは localhost:9200 でそのまま ES に繋がるため、
# search_demo/*.ipynb を無修正で使える。
#
# ES は 127.0.0.1 のみで待ち受ける (run_es.sh の設定)。
# Jupyter も 127.0.0.1 に bind し、SSH トンネル経由で使う。
# 共有クラスタなので、認証無効の ES をネットワークに晒さない。
#
# 投入 (必ずリポジトリルートから):
#   cd /workspace/filesrv01/yoshikawa/260805_make_biore_ds/pubmed_handler
#   mkdir -p logs
#   sbatch env/serve_slurm.sh
#
# 接続手順はジョブのログに出力される:
#   tail -f logs/pubmed_es_jupyter_<jobid>.out
#
# 終了:
#   scancel <jobid>
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
    echo "          cd <path>/pubmed_handler && sbatch env/serve_slurm.sh"
    exit 1
fi

source "${ROOT_DIR}/env/common.sh"

ES_SIF="${ROOT_DIR}/sif/elasticsearch.sif"
ENV_SIF="${ROOT_DIR}/env.sif"

LOG_DIR="${ROOT_DIR}/logs/${SLURM_JOB_ID}"
ES_LOG="${LOG_DIR}/elasticsearch.out"

mkdir -p "${LOG_DIR}"

export ES_HOST="http://localhost:9200"
# 常駐サービスは検索も行うため、スモークテストより厚めに取る
export ES_HEAP="${ES_HEAP:-8g}"

# =====================================================
# 自動終了の設定
#
# 消し忘れでノードを占有し続けないよう、使われなくなったら
# Jupyter が自身を終了する。Jupyter はフォアグラウンドなので、
# 終了すればジョブも終わり trap で ES も停止する。
#
#   KERNEL_CULL_TIMEOUT : 無操作のカーネル/ターミナルを片付けるまで
#   IDLE_TIMEOUT        : カーネル/ターミナルが 0 個の状態が続いたら終了
#
# shutdown_no_activity_timeout はカーネルが 1 つも無い時にしか
# 効かないため、先に cull で片付ける必要がある。
# 実際に終了するまでは最大 KERNEL_CULL_TIMEOUT + IDLE_TIMEOUT。
# =====================================================

KERNEL_CULL_TIMEOUT="${KERNEL_CULL_TIMEOUT:-1800}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-3600}"

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

if curl -s -m 3 "${ES_HOST}" > /dev/null 2>&1; then
    echo "[FATAL] ${ES_HOST} は既に使用中です。"
    echo "        同一ノードで別の Elasticsearch が動作している可能性があります。"
    exit 1
fi

# ノードを跨いだ二重起動 (NFS 上の esdata を同時に開く) を防ぐ
check_no_other_es_job

# =====================================================
# Elasticsearch 起動
#
# Jupyter も apptainer で動かすため、ES はネイティブ側で
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
    sleep 5
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

# =====================================================
# Jupyter の接続情報
#
# ポートとトークンは start_jupyter.sh と同じ方式で用意する。
# =====================================================

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(16))')

COMPUTE_NODE=$(hostname -s)
COMPUTE_SSH_PORT=49152

echo
echo "=================================================================="
echo "Elasticsearch + JupyterLab on: ${COMPUTE_NODE}  (job ${SLURM_JOB_ID})"
echo
echo "[STEP 1: SSH トンネルを張る]"
echo "login node で新しいターミナルを開いて実行:"
echo "  ssh -N -L ${PORT}:localhost:${PORT} -p ${COMPUTE_SSH_PORT} ${COMPUTE_NODE}"
echo
echo "  * 作業中はそのターミナルを開いたままにする"
echo "  * 'Address already in use' が出たら最初の ${PORT} を別の数字に変える"
echo
echo "[STEP 2: JupyterLab に接続]"
echo "  http://localhost:${PORT}/?token=${TOKEN}"
echo
echo "[STEP 3: notebook から Elasticsearch を使う]"
echo "  ES は同じノードで動いているため、そのまま繋がる:"
echo "    from elasticsearch import Elasticsearch"
echo "    es = Elasticsearch('http://localhost:9200')"
echo
echo "[自動終了]"
echo "  無操作のカーネル/ターミナルは $((KERNEL_CULL_TIMEOUT / 60)) 分で片付けられ、"
echo "  その状態がさらに $((IDLE_TIMEOUT / 60)) 分続くとジョブごと自動終了する。"
echo "  (消し忘れでノードを占有しないため)"
echo
echo "すぐ終了する場合: scancel ${SLURM_JOB_ID}"
echo "=================================================================="
echo

# =====================================================
# JupyterLab 起動 (フォアグラウンド)
#
# Jupyter が終了するとジョブも終わり、trap で ES が停止する。
# =====================================================

apptainer exec \
    --bind /workspace \
    --env ES_HOST="${ES_HOST}" \
    --env DATA_DIR="${ROOT_DIR}/data" \
    "${ENV_SIF}" \
    bash -c "
        set -euo pipefail

        source ${ROOT_DIR}/.venv/bin/activate

        cd ${ROOT_DIR}

        jupyter lab \
            --ip=127.0.0.1 \
            --port=${PORT} \
            --no-browser \
            --ServerApp.token='${TOKEN}' \
            --ServerApp.shutdown_no_activity_timeout=${IDLE_TIMEOUT} \
            --MappingKernelManager.cull_idle_timeout=${KERNEL_CULL_TIMEOUT} \
            --MappingKernelManager.cull_interval=300 \
            --MappingKernelManager.cull_connected=True \
            --TerminalManager.cull_inactive_timeout=${KERNEL_CULL_TIMEOUT} \
            --TerminalManager.cull_interval=300
    "
