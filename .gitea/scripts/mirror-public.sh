#!/usr/bin/env bash
# main -> GitHub 퍼블릭 미러링
# private 마커 기반으로 비공개 리소스 제거 후 GitHub main에 커밋 누적
set -euo pipefail

[ -z "${GITHUB_COM_TOKEN:-}" ] && { echo "GITHUB_COM_TOKEN not set, skip"; exit 0; }

MAIN_SHA=$(git rev-parse --short main)

git config user.name "${GITHUB_ACTOR:-mirror-bot}"
git config user.email "${GITHUB_ACTOR_ID:+${GITHUB_ACTOR_ID}+}${GITHUB_ACTOR:-mirror-bot}@users.noreply.github.com"

git remote add github "https://${GITHUB_COM_TOKEN}@github.com/${MIRROR_REPO}.git"
git fetch github main 2>/dev/null || true

# GitHub main 위에 브랜치 생성, main 내용으로 교체
git checkout -B mirror-staging github/main 2>/dev/null || git checkout --orphan mirror-staging
git rm -rf --quiet . 2>/dev/null || true
git checkout main -- .

# ──── sanitize ────────────────────────

rm -f .env.config

find . -name '*.yaml' -o -name '.env.example' | xargs sed -i '/ # private$/d'

rm -f 0-core/flux-system/image-policies-apps.yaml

sed -i 's/"matchPackageNames": \[.*\]/"matchPackageNames": ["my-custom-app"]/' renovate.json

# 3-apps: kustomization에서 참조 해제된 리소스 정리
find 3-apps -maxdepth 1 -mindepth 1 ! -name 'kustomization.yaml' | while read entry; do
  grep -qF "$(basename "$entry")" 3-apps/kustomization.yaml || rm -rf "$entry"
done

for k in 3-apps/*/kustomization.yaml; do
  dir=$(dirname "$k")
  find "$dir" -maxdepth 1 -name '*.yaml' ! -name 'kustomization.yaml' | while read f; do
    grep -qF "$(basename "$f")" "$k" || rm -f "$f"
  done
done

find 3-apps -type d -empty -delete

# ──── 커밋 & push ────────────────────────

git add -A

if git diff --cached --quiet; then
  echo "No changes to mirror"
  exit 0
fi

MAIN_MSG=$(git log main -1 --format=%s)
git commit -m "${MAIN_MSG} [mirror from ${MAIN_SHA}]"
git push github mirror-staging:main
