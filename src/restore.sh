#!/bin/sh

set -eo pipefail

# -------------------------
# Проверка обязательных переменных
# -------------------------
if [ "${S3_ACCESS_KEY_ID:-**None**}" = "**None**" ] || [ "${S3_SECRET_ACCESS_KEY:-**None**}" = "**None**" ] || [ "${S3_BUCKET:-**None**}" = "**None**" ]; then
  echo "You need to set S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, and S3_BUCKET"
  exit 1
fi

if [ "${POSTGRES_HOST:-**None**}" = "**None**" ]; then
  echo "You need to set POSTGRES_HOST"
  exit 1
fi

if [ "${POSTGRES_USER:-**None**}" = "**None**" ]; then
  echo "You need to set POSTGRES_USER"
  exit 1
fi

if [ "${POSTGRES_PASSWORD:-**None**}" = "**None**" ]; then
  echo "You need to set POSTGRES_PASSWORD"
  exit 1
fi

# -------------------------
# AWS CLI args
# -------------------------
if [ "${S3_ENDPOINT:-}" != "" ]; then
  AWS_ARGS="--endpoint-url ${S3_ENDPOINT}"
else
  AWS_ARGS=""
fi

export AWS_ACCESS_KEY_ID=$S3_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$S3_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=$S3_REGION
export PGPASSWORD=$POSTGRES_PASSWORD

POSTGRES_HOST_OPTS="-h $POSTGRES_HOST -p ${POSTGRES_PORT:-5432} -U $POSTGRES_USER $POSTGRES_EXTRA_OPTS"

if [ -z "${S3_PREFIX+x}" ]; then
  S3_PREFIX="/"
else
  S3_PREFIX="/${S3_PREFIX}/"
fi

s3_uri_base="s3://${S3_BUCKET}${S3_PREFIX}"

# -------------------------
# Восстановление всех баз
# -------------------------
if [ "${POSTGRES_BACKUP_ALL:-false}" = "true" ]; then
  echo "POSTGRES_BACKUP_ALL=true → restoring all accessible databases"

  # находим список всех баз
  DB_LIST=$(psql $POSTGRES_HOST_OPTS -d postgres -Atc "
    SELECT datname FROM pg_database
    WHERE datallowconn AND datistemplate = false
  ")

  for DB in $DB_LIST; do
    echo "---------------------------------------"
    echo "Restoring database: $DB"

    # ищем последний бэкап в S3
    BACKUP_KEY=$(aws $AWS_ARGS s3 ls "${s3_uri_base}" | grep "^${DB}_" | sort | tail -n1 | awk '{print $4}')
    if [ -z "$BACKUP_KEY" ]; then
      echo "⚠️  No backup found for $DB, skipping..."
      continue
    fi

    echo "Fetching backup from S3: $BACKUP_KEY"
    aws $AWS_ARGS s3 cp "${s3_uri_base}/${BACKUP_KEY}" "${DB}.sql.gz${ENCRYPTION_PASSWORD:+.enc}"

    # расшифровка
    if [ -n "${ENCRYPTION_PASSWORD:-}" ]; then
      echo "Decrypting ${DB}.sql.gz.enc..."
      openssl enc -d -aes-256-cbc -pbkdf2 -in "${DB}.sql.gz.enc" -out "${DB}.sql.gz" -k "$ENCRYPTION_PASSWORD"
      rm "${DB}.sql.gz.enc"
    fi

    # восстановление
    echo "Restoring $DB..."
    gunzip -c "${DB}.sql.gz" | psql $POSTGRES_HOST_OPTS -d "$DB"
    rm "${DB}.sql.gz"
    echo "✅ $DB restored"
  done

else
  # -------------------------
  # Восстановление отдельных баз
  # -------------------------
  OIFS="$IFS"
  IFS=','

  for DB in $POSTGRES_DATABASE; do
    IFS="$OIFS"
    echo "---------------------------------------"
    echo "Restoring single database: $DB"

    BACKUP_KEY=$(aws $AWS_ARGS s3 ls "${s3_uri_base}" | grep "^${DB}_" | sort | tail -n1 | awk '{print $4}')
    if [ -z "$BACKUP_KEY" ]; then
      echo "⚠️  No backup found for $DB, skipping..."
      continue
    fi

    echo "Fetching backup from S3: $BACKUP_KEY"
    aws $AWS_ARGS s3 cp "${s3_uri_base}/${BACKUP_KEY}" "${DB}.sql.gz${ENCRYPTION_PASSWORD:+.enc}"

    if [ -n "${ENCRYPTION_PASSWORD:-}" ]; then
      echo "Decrypting ${DB}.sql.gz.enc..."
      openssl enc -d -aes-256-cbc -pbkdf2 -in "${DB}.sql.gz.enc" -out "${DB}.sql.gz" -k "$ENCRYPTION_PASSWORD"
      rm "${DB}.sql.gz.enc"
    fi

    echo "Restoring $DB..."
    gunzip -c "${DB}.sql.gz" | psql $POSTGRES_HOST_OPTS -d "$DB"
    rm "${DB}.sql.gz"
    echo "✅ $DB restored"
  done
fi

echo "Restore complete."
