#!/bin/sh
set -eu

RESTORE_DB="restore_test_$$"
FAILED=0

# 최신 덤프 파일 탐색
LATEST_DUMP=""
for f in /backup/pg_dump_*.dump; do
  [ -f "$f" ] || continue
  if [ -z "$LATEST_DUMP" ] || [ "$f" -nt "$LATEST_DUMP" ]; then
    LATEST_DUMP="$f"
  fi
done

if [ -z "$LATEST_DUMP" ]; then
  echo "ERROR: No dump files found in /backup/"
  exit 1
fi

echo "Latest dump: $LATEST_DUMP"
echo "Testing restore into temporary database: $RESTORE_DB"

# 임시 DB 생성
PGPASSWORD="$DB_PASSWORD_POSTGRES" createdb -U postgres -h postgres "$RESTORE_DB"

# 실패 시에도 임시 DB를 반드시 삭제하기 위한 trap
cleanup() {
  echo "Dropping temporary database: $RESTORE_DB"
  PGPASSWORD="$DB_PASSWORD_POSTGRES" dropdb -U postgres -h postgres --if-exists "$RESTORE_DB"
}
trap cleanup EXIT

# pg_restore 실행
if PGPASSWORD="$DB_PASSWORD_POSTGRES" pg_restore -U postgres -h postgres -d "$RESTORE_DB" "$LATEST_DUMP"; then
  echo "Restore succeeded."

  # 기본 검증: 테이블 수 확인
  TABLE_COUNT=$(PGPASSWORD="$DB_PASSWORD_POSTGRES" psql -U postgres -h postgres -d "$RESTORE_DB" -t -c \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")
  TABLE_COUNT=$(echo "$TABLE_COUNT" | tr -d ' ')
  echo "Restored tables: $TABLE_COUNT"

  if [ "$TABLE_COUNT" -lt 1 ]; then
    echo "WARNING: No tables found after restore."
    FAILED=1
  fi
else
  echo "ERROR: pg_restore failed!"
  FAILED=1
fi

if [ "$FAILED" -eq 1 ]; then
  echo "Restore test FAILED."
  exit 1
fi

echo "Restore test PASSED."
