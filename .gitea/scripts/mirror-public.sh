#!/usr/bin/env bash
# main 스냅샷에서 private 마커를 걷어낸 뒤 GitHub main에 커밋을 누적한다.
#
# 마커 문법 (주석 기호 '#', '--', '//')
#   <주석> private          라인 삭제
#   <주석> private:begin    블록 시작 (마커 라인 포함 삭제)
#   <주석> private:end      블록 종료
#
# kustomization.yaml의 resources 항목에 마커가 붙으면 참조 경로까지 삭제한다.
# 삭제한 이름이 트리나 커밋 제목에 남아 있으면 push 전에 실패한다.
set -euo pipefail

[ -z "${GITHUB_COM_TOKEN:-}" ] && { echo "GITHUB_COM_TOKEN not set, skip"; exit 0; }

# ──── 마커 정규식 ────

CMT='(#|--|\/\/)'
RE_BLOCK_BEGIN="(^|[[:space:]])${CMT}[[:space:]]*private:begin[[:space:]]*$"
RE_BLOCK_END="(^|[[:space:]])${CMT}[[:space:]]*private:end[[:space:]]*$"
RE_PRIVATE_LINE="(^|[[:space:]])${CMT}[[:space:]]*private[[:space:]]*$"
RE_PRIVATE_RESOURCE="^[[:space:]]*-[[:space:]]+([^[:space:]]+)[[:space:]]+#[[:space:]]*private[[:space:]]*$"

RE_TOKEN_EXCLUDE='^(secrets|kustomization|configuration|config)$'

# NODE_STORAGE, DEFAULT_USERNAME은 값이 각각 일반 영단어와 GitHub 계정명이라 제외
RE_INFRA_KEY='^(NODE_(MASTER|COMPUTE|IOT)|DOMAIN_[A-Z]+|ACME_EMAIL|REGISTRY|INFISICAL_PROJECT_SLUG|PATH_WORKSPACE|B2_[A-Z]+_BUCKET)='

# private 패키지명을 걷어낸 renovate 규칙에 남길 예시 값
PUBLIC_PACKAGE_PLACEHOLDER='my-custom-app'

WORK_DIR=$(mktemp -d)
PRIVATE_PATHS="${WORK_DIR}/private-paths"
PRIVATE_TOKENS="${WORK_DIR}/private-tokens"
trap 'rm -rf "${WORK_DIR}"' EXIT
: > "${PRIVATE_PATHS}"
: > "${PRIVATE_TOKENS}"

# ──── 미러 브랜치 준비 ────

MAIN_SHA=$(git rev-parse --short main)

git config user.name "${GITHUB_ACTOR:-mirror-bot}"
git config user.email "${GITHUB_ACTOR_ID:+${GITHUB_ACTOR_ID}+}${GITHUB_ACTOR:-mirror-bot}@users.noreply.github.com"

git remote add github "https://${GITHUB_COM_TOKEN}@github.com/${MIRROR_REPO}.git"
git fetch github main 2>/dev/null || true

git checkout -B mirror-staging github/main 2>/dev/null || git checkout --orphan mirror-staging
git rm -rf --quiet . 2>/dev/null || true
git checkout main -- .

# ──── 헬퍼 ────

list_text_files() {
  git ls-files | while IFS= read -r f; do
    [ -f "$f" ] || continue
    grep -Iq . "$f" 2>/dev/null && printf '%s\n' "$f"
  done
}

assert_balanced_markers() {
  local f="$1" opened closed
  opened=$(grep -cE "${RE_BLOCK_BEGIN}" "$f" || true)
  closed=$(grep -cE "${RE_BLOCK_END}" "$f" || true)
  [ "${opened}" = "${closed}" ] || {
    echo "ERROR: unbalanced private block markers (begin=${opened}, end=${closed}): $f" >&2
    exit 1
  }
}

collect_tokens() {
  local p="$1"
  basename "$p" | sed -E 's/\.[^.]+$//'
  [ -d "$p" ] && find "$p" -mindepth 1 -exec basename {} \; | sed -E 's/\.[^.]+$//'
  return 0
}

# ──── 1. private 리소스 경로 수집 ────

while IFS= read -r k; do
  dir=$(dirname "$k")
  dir="${dir#./}"
  sed -nE "s|${RE_PRIVATE_RESOURCE}|\1|p" "$k" | while IFS= read -r rel; do
    printf '%s\n' "${dir}/${rel}"
  done
done < <(git ls-files '*kustomization.yaml') > "${PRIVATE_PATHS}"

# ──── 2. 인프라 설정 파일 제거 ────

# .env.config는 미러에서 빠지지만 그 값이 매니페스트나 커밋 제목에 남을 수 있다.
grep -E "${RE_INFRA_KEY}" .env.config \
  | sed -E 's@^[A-Z0-9_]+=@@; s@[[:space:]]+#.*$@@' \
  | awk 'length($0) >= 4' >> "${PRIVATE_TOKENS}"

rm -f .env.config

# ──── 3. 마커 sanitize ────

while IFS= read -r f; do
  assert_balanced_markers "$f"
  sed -i -E \
    -e "/${RE_BLOCK_BEGIN}/,/${RE_BLOCK_END}/d" \
    -e "/${RE_PRIVATE_LINE}/d" \
    "$f"
done < <(list_text_files)

# ──── 4. private 리소스 삭제 ────

while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ ! -e "$p" ]; then
    echo "WARN: private resource not found, skip: $p" >&2
    continue
  fi
  collect_tokens "$p" >> "${PRIVATE_TOKENS}"
  rm -rf "$p"
  echo "removed private resource: $p"
done < "${PRIVATE_PATHS}"

find 0-core 1-data 2-platform 3-apps components -type d -empty -delete 2>/dev/null || true

# ──── 5. 값 재작성 ────

.gitea/scripts/sanitize-renovate.mjs "${PRIVATE_TOKENS}" "${PUBLIC_PACKAGE_PLACEHOLDER}"

# ──── 6. 노출 검증 ────

leaked=0
MIRROR_FILES="${WORK_DIR}/mirror-files"
list_text_files > "${MIRROR_FILES}"

# xargs 종료 코드는 배치가 나뉘면 신뢰할 수 없으므로 출력 유무로 판정한다.
hits=$(xargs -r -d '\n' grep -nHE "${RE_PRIVATE_LINE}|${RE_BLOCK_BEGIN}|${RE_BLOCK_END}" < "${MIRROR_FILES}" || true)
if [ -n "${hits}" ]; then
  printf '%s\n' "${hits}" >&2
  echo "ERROR: private marker survived sanitize" >&2
  leaked=1
fi

while IFS= read -r token; do
  [ -n "$token" ] || continue
  hits=$(xargs -r -d '\n' grep -nHiF "$token" < "${MIRROR_FILES}" || true)
  if [ -n "${hits}" ]; then
    printf '%s\n' "${hits}" >&2
    echo "ERROR: private resource name '${token}' leaked into mirror tree" >&2
    leaked=1
  fi
done < <(sort -u "${PRIVATE_TOKENS}" | grep -Ev "${RE_TOKEN_EXCLUDE}" || true)

[ "$leaked" -eq 0 ] || exit 1

# ──── 7. 커밋 & push ────

git add -A

if git diff --cached --quiet; then
  echo "No changes to mirror"
  exit 0
fi

# main tip 제목은 미러 diff와 무관할 수 있다.
# private 전용 푸시로 밀려 있던 공개 변경이 뒤늦게 커밋되면 그 private PR 제목이 따라온다.
MAIN_MSG=$(git log main -1 --format=%s)
MAIN_AUTHOR=$(git log main -1 --format=%an)
MIRROR_MSG="$MAIN_MSG"

while IFS= read -r token; do
  [ -n "$token" ] || continue
  if printf '%s' "${MAIN_MSG}" | grep -qiF "$token"; then
    echo "private token '${token}' in commit subject -- using generic message"
    MIRROR_MSG="chore: sync public manifests"
    break
  fi
done < <(sort -u "${PRIVATE_TOKENS}" | grep -Ev "${RE_TOKEN_EXCLUDE}" || true)

if [ "$MAIN_AUTHOR" = "Renovate Bot" ]; then
  MIRROR_MSG="chore(deps): packages updated by Renovate Bot"
fi

git commit -m "${MIRROR_MSG} [mirror from ${MAIN_SHA}]"
git push github mirror-staging:main
