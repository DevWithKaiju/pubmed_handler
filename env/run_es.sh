#!/bin/bash

set -e

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

ES_SIF=${ROOT_DIR}/sif/elasticsearch.sif

ESDATA=${ROOT_DIR}/data/esdata
ESCONFIG=${ROOT_DIR}/data/esconfig
ESLOGS=${ROOT_DIR}/data/eslogs

# 用途によって必要なヒープが違うため上書き可能にする
#   スモークテスト: 4g で十分
#   本番投入・常駐サービス: 8g 以上が望ましい
ES_HEAP=${ES_HEAP:-4g}

mkdir -p "${ESDATA}" "${ESLOGS}"

# =====================================================
# config の準備 (初回のみ)
#
# Apptainer のコンテナは読み取り専用のため、Elasticsearch が
# 起動時に config/ へ keystore を書き込めず失敗する
# (Docker と違い書き込み可能レイヤーが無い)。
# SIF から config を取り出してホスト側に置き、bind して渡す。
#
# 設定を --env で渡していないのは、discovery.type のような
# ドットを含む名前がシェルの変数名として不正であり、
# Apptainer の env 注入時に落とされてしまうため
# (Docker はドット付きの環境変数名を許すので compose 版では
#  動いていた)。
# =====================================================

if [ ! -f "${ESCONFIG}/.prepared" ]; then

    echo "[INFO] Extracting config from SIF..."

    mkdir -p "${ESCONFIG}"

    # /mnt 経由でコンテナ内の config をホスト側へコピーする。
    # cp -a は所有者の保存に失敗する (非 root のため) ので使わない。
    apptainer exec \
      --bind "${ESCONFIG}:/mnt" \
      "${ES_SIF}" \
      cp -r /usr/share/elasticsearch/config/. /mnt/

    chmod -R u+rwX "${ESCONFIG}"

    # イメージ付属の elasticsearch.yml は network.host 等を含むため、
    # 追記すると YAML のキー重複になる。まるごと置き換える。
    cat > "${ESCONFIG}/elasticsearch.yml" <<'EOF'
cluster.name: pubmed-es
node.name: pubmed-es-node

network.host: 127.0.0.1
http.port: 9200

discovery.type: single-node

xpack.security.enabled: false
xpack.security.enrollment.enabled: false
EOF

    touch "${ESCONFIG}/.prepared"

    echo "[INFO] Config prepared at ${ESCONFIG}"
fi

ulimit -n 65535

echo "[INFO] Starting Elasticsearch... (heap=${ES_HEAP})"

apptainer exec \
  --cleanenv \
  --env ES_JAVA_OPTS="-Xms${ES_HEAP} -Xmx${ES_HEAP}" \
  --bind ${ESDATA}:/usr/share/elasticsearch/data \
  --bind ${ESCONFIG}:/usr/share/elasticsearch/config \
  --bind ${ESLOGS}:/usr/share/elasticsearch/logs \
  ${ES_SIF} \
  /usr/local/bin/docker-entrypoint.sh eswrapper
