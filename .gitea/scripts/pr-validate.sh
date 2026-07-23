#!/usr/bin/env sh
# PR 검증 -- yamllint + 4계층 kustomize 빌드
set -eu

VENV=/cache/venv/homelab-cluster

VERSION=$(sed -nE 's/^[[:space:]]*rev:[[:space:]]*v(.+)$/\1/p' .pre-commit-config.yaml | head -1)
[ -n "${VERSION}" ] || { echo "ERROR: .pre-commit-config.yaml에서 yamllint 버전을 읽지 못했다" >&2; exit 1; }

installed=$("${VENV}/bin/yamllint" --version 2>/dev/null | awk '{print $2}' || true)

if [ "${installed}" != "${VERSION}" ]; then
  echo "yamllint ${VERSION} 설치 (현재: ${installed:-없음})"
  # 러너 이미지에 ensurepip이 없어 venv 생성에 python3-venv가 필요하다
  apt-get update -qq
  apt-get install -y -qq python3-venv >/dev/null
  rm -rf "${VENV}"
  python3 -m venv "${VENV}"
  "${VENV}/bin/pip" install --quiet "yamllint==${VERSION}"
fi

"${VENV}/bin/yamllint" --strict -c .yamllint.yml .
echo "yamllint OK"

for tier in 0-core 1-data 2-platform 3-apps; do
  kubectl kustomize "${tier}" > /dev/null
  echo "kustomize build ${tier} OK"
done
