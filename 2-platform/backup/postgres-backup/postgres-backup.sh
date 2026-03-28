#!/bin/sh
set -eu

TIMESTAMP=$(date +%Y%m%d%H%M%S)
FAILED=0

# 템플릿 DB를 제외한 모든 DB 감지
DATABASES=$(PGPASSWORD="$DB_PASSWORD_POSTGRES" psql -U postgres -h postgres -t -c \
  "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;")

# IFS 개행 설정으로 word splitting 방지
IFS='
'
for DB in $DATABASES; do
  DB=$(echo "$DB" | tr -d ' ')
  [ -z "$DB" ] && continue
  DUMP_FILE="/backup/pg_dump_${DB}_${TIMESTAMP}.dump"
  echo "Dumping $DB to $DUMP_FILE..."
  if PGPASSWORD="$DB_PASSWORD_POSTGRES" pg_dump -U postgres -h postgres -d "$DB" -F c -f "$DUMP_FILE"; then
    echo "  $DB dump complete."
  else
    echo "  ERROR: $DB dump failed!"
    FAILED=1
  fi
done

if [ "$FAILED" -eq 0 ]; then
  echo "All dumps succeeded. Cleaning backups older than 7 days..."
  find /backup -name "pg_dump_*.dump" -mtime +7 -delete
else
  echo "Some dumps failed. Skipping cleanup to preserve existing backups."
  exit 1
fi
echo "Done."
