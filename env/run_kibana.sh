#!/bin/bash

set -e

# =====================================================
# Kibana 起動 (フォアグラウンド)
#
# ES と同じ compute node 上で動かし、127.0.0.1 のみで待ち受ける。
# SSH トンネル経由でブラウザから使う。
#
# 必須の環境変数:
#   KIBANA_PORT : 待ち受けポート (serve_slurm.sh が空きポートを払い出す)
# =====================================================

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

KIBANA_SIF=${ROOT_DIR}/sif/kibana.sif

KIBANACONFIG=${ROOT_DIR}/data/kibanaconfig
KIBANADATA=${ROOT_DIR}/data/kibanadata

ES_HOST=${ES_HOST:-http://localhost:9200}

if [ -z "${KIBANA_PORT:-}" ]; then
    echo "[FATAL] KIBANA_PORT が設定されていません"
    exit 1
fi

mkdir -p "${KIBANADATA}"

# =====================================================
# config の準備 (初回のみ)
#
# run_es.sh と同じ理由。Apptainer のコンテナは読み取り専用だが、
# Kibana は起動時に config/ へ keystore を、data/ へ uuid を書く。
# SIF から config を取り出してホスト側に置き、bind して渡す。
# =====================================================

if [ ! -f "${KIBANACONFIG}/.prepared" ]; then

    echo "[INFO] Extracting config from SIF..."

    mkdir -p "${KIBANACONFIG}"

    # /mnt 経由でコンテナ内の config をホスト側へコピーする。
    # cp -a は所有者の保存に失敗する (非 root のため) ので使わない。
    apptainer exec \
      --bind "${KIBANACONFIG}:/mnt" \
      "${KIBANA_SIF}" \
      cp -r /usr/share/kibana/config/. /mnt/

    chmod -R u+rwX "${KIBANACONFIG}"

    touch "${KIBANACONFIG}/.prepared"

    echo "[INFO] Config prepared at ${KIBANACONFIG}"
fi

# =====================================================
# kibana.yml
#
# ポートは起動のたびに変わるため毎回書き出す。
# イメージ付属の yml は server.host 等を含むため、
# 追記ではなく置き換える (YAML のキー重複を避ける)。
# =====================================================

cat > "${KIBANACONFIG}/kibana.yml" <<EOF
server.host: 127.0.0.1
server.port: ${KIBANA_PORT}
server.publicBaseUrl: "http://localhost:${KIBANA_PORT}"

elasticsearch.hosts: ["${ES_HOST}"]

# 共有クラスタなので外部への送信は止める
telemetry.enabled: false
telemetry.optIn: false
EOF

echo "[INFO] Starting Kibana... (port=${KIBANA_PORT}, es=${ES_HOST})"

apptainer exec \
  --cleanenv \
  --bind "${KIBANACONFIG}:/usr/share/kibana/config" \
  --bind "${KIBANADATA}:/usr/share/kibana/data" \
  "${KIBANA_SIF}" \
  /usr/share/kibana/bin/kibana
