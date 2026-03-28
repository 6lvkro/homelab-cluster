#!/bin/bash
# PostgreSQL 최초 초기화 시 서비스별 DB/유저 생성
# 데이터 디렉터리가 비어있을 때만 docker-entrypoint-initdb.d에 의해 실행
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-'EOSQL'
    -- grafana (2-platform/observability)
    CREATE DATABASE grafana;
    CREATE USER grafana WITH PASSWORD '${DB_PASSWORD_GRAFANA}';
    GRANT ALL PRIVILEGES ON DATABASE grafana TO grafana;
    \c grafana
    GRANT ALL ON SCHEMA public TO grafana;

    -- immich (3-apps/media) -- postgres 슈퍼유저 직접 사용 (확장 권한 필요)
    CREATE DATABASE immich;
    \c immich
    CREATE EXTENSION IF NOT EXISTS vectors;
    CREATE EXTENSION IF NOT EXISTS cube;
    CREATE EXTENSION IF NOT EXISTS earthdistance CASCADE;

    -- openwebui (3-apps/ai)
    CREATE DATABASE openwebui;
    CREATE USER openwebui WITH PASSWORD '${DB_PASSWORD_OPENWEBUI}';
    GRANT ALL PRIVILEGES ON DATABASE openwebui TO openwebui;
    \c openwebui
    GRANT ALL ON SCHEMA public TO openwebui;

    -- paperless (3-apps/tools)
    CREATE DATABASE paperless;
    CREATE USER paperless WITH PASSWORD '${DB_PASSWORD_PAPERLESS}';
    GRANT ALL PRIVILEGES ON DATABASE paperless TO paperless;
    \c paperless
    GRANT ALL ON SCHEMA public TO paperless;

    -- geulium (3-apps/media)
    CREATE DATABASE geulium;
    CREATE USER geulium WITH PASSWORD '${DB_PASSWORD_GEULIUM}';
    GRANT ALL PRIVILEGES ON DATABASE geulium TO geulium;
    \c geulium
    GRANT ALL ON SCHEMA public TO geulium;

    -- infisical (infisical namespace) -- 시크릿 관리
    CREATE DATABASE infisical;
    CREATE USER infisical WITH PASSWORD '${DB_PASSWORD_INFISICAL}';
    GRANT ALL PRIVILEGES ON DATABASE infisical TO infisical;
    \c infisical
    GRANT ALL ON SCHEMA public TO infisical;

EOSQL

# gitea는 초기 설치 시 SQLite 사용 (이후 수동 마이그레이션 시 DB 생성 필요)
