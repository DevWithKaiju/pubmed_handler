#!/bin/bash
# =====================================================
# Elasticsearch ジョブ間で共有するヘルパー
#
# 各ジョブスクリプトから source して使う:
#   source "${ROOT_DIR}/env/common.sh"
# =====================================================

# -----------------------------------------------------
# 他の Elasticsearch ジョブが動いていないか確認する
#
# data/esdata は NFS 上にあるため、別ノードで 2 つ目の ES が
# 起動すると同じデータディレクトリを同時に開いてしまい、
# インデックスが壊れる。
#
# これを防いでいるのは ES の node.lock だけだが、NFS 上の
# ファイルロックは確実ではない (ES が NFS を非推奨とする理由)。
# そのため squeue 側でも重複を弾く。
#
# 各スクリプトのポート 9200 チェックは同一ノードしか見ないので、
# こちらはノードを跨いだ衝突を防ぐためのもの。
#
# 対象は job-name が pubmed_es_ で始まるジョブ
# (pubmed_es_smoke / pubmed_es_jupyter / pubmed_es_index)。
# -----------------------------------------------------

check_no_other_es_job() {
    local snapshot
    local others

    # squeue 自体が失敗した場合は「重複なし」とみなさず中止する
    # (確認できないまま起動する方が危険なため)
    if ! snapshot=$(squeue -u "${USER}" -h -o "%i %j %T %N" 2>/dev/null); then
        echo "[FATAL] squeue の実行に失敗しました。"
        echo "        ES ジョブの重複を確認できないため中止します。"
        return 1
    fi

    others=$(printf '%s\n' "${snapshot}" \
             | grep 'pubmed_es_' \
             | grep -v "^${SLURM_JOB_ID} " \
             || true)

    if [ -n "${others}" ]; then
        echo "[FATAL] 他の Elasticsearch ジョブが存在します。"
        echo "        同じ esdata を 2 プロセスが開くとインデックスが壊れます。"
        echo "        先に終了させてください (scancel <jobid>)。"
        echo
        echo "  JOBID NAME STATE NODE"
        echo "${others}"
        return 1
    fi

    echo "[INFO] 他の Elasticsearch ジョブなし"
}
