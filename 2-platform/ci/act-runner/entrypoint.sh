#!/bin/sh
set -eu

# 캐시 영속화 (/root/.cache/act -> /data/.cache/act)
mkdir -p /data/.cache/act /root/.cache
ln -sfn /data/.cache/act /root/.cache/act

if ! command -v node >/dev/null 2>&1; then
  apk add --no-cache nodejs
fi

# 자체 CA 인증서 신뢰 (Gitea registry token auth용)
if [ -f /usr/local/share/ca-certificates/homelab-ca.crt ]; then
  update-ca-certificates 2>/dev/null || true
fi

# DinD: Docker 데몬 백그라운드 시작 (GITEA_INSTANCE_URL에서 host:port 추출)
dockerd --host=unix:///var/run/docker.sock --host=tcp://0.0.0.0:2375 --tls=false --insecure-registry="$${GITEA_INSTANCE_URL#*://}" --mtu=1400 &
sleep 3

if [ ! -f /data/.runner ]; then
  act_runner register \
    --instance "$GITEA_INSTANCE_URL" \
    --token "$GITEA_RUNNER_REGISTRATION_TOKEN" \
    --name "$GITEA_RUNNER_NAME" \
    --labels "$GITEA_RUNNER_LABELS" \
    --config /config/config.yaml \
    --no-interactive
fi

exec act_runner daemon --config /config/config.yaml
