#!/bin/sh
set -u
set -o pipefail

source ./env.sh

s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}"
export PGPASSWORD=$POSTGRES_PASSWORD

# aws args (endpoint)
if [ "${S3_ENDPOINT}" == "**None**" ]; then
  aws_args=""
else
  aws_args="--endpoint-url ${S3_ENDPOINT}"
fi

# ---------------------------
# RESTORE ALL DATABASES
# ---------------------------
if [ "${POSTGRES_BACKUP_ALL:-false}" = "true" ]; then
  echo "POSTGRES_BACKUP_ALL=true → restoring ALL databases"

  # получаем список всех дампов баз из S3
  DB_KEYS=$(aws $aws_args s3 ls "${s3_uri_base}" \
    | grep '\.sql\.gz' \
    | awk '{print $4}' \
    | sort
  )

  if [ -z "$DB_KEYS" ]; then
    echo "No database backups found in S3"
    exit 1
  fi

  for key_suffix in $DB_KEYS; do
    DB_NAME=$(echo "$key_suffix" | sed -E 's/_.*\.sql\.gz$//')
    echo "Restoring database $DB_NAME from $key_suffix ..."

    aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" "dump.sql.gz${ENCRYPTION_PASSWORD:+.enc}"

    # decrypt if needed
    if [ -n "${ENCRYPTION_PASSWORD:-}" ]; then
      echo "Decrypting backup for $DB_NAME ..."
      openssl enc -d -aes-256-cbc \
        -in dump.sql.gz.enc \
        -out dump.sql.gz \
        -k "$ENCRYPTION_PASSWORD" || { echo "Decryption failed for $DB_NAME"; rm dump.sql.gz.enc; continue; }
      rm dump.sql.gz.enc
    fi

    # create database if not exists
    echo "Ensuring database $DB_NAME exists..."
    psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 || \
      psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -c "CREATE DATABASE \"$DB_NAME\""

    # restore
    echo "Restoring $DB_NAME ..."
    gunzip -c dump.sql.gz | psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$DB_NAME" || \
      echo "⚠️ Restore failed for $DB_NAME, skipping..."

    rm dump.sql.gz
    echo "✅ $DB_NAME restored"
  done

  echo "All database restores complete."
  exit 0
fi

# ---------------------------
# RESTORE SINGLE DATABASE
# ---------------------------
if [ -z "${POSTGRES_DATABASE:-}" ]; then
  echo "POSTGRES_DATABASE is not set, cannot restore single database"
  exit 1
fi

# find latest backup if timestamp not provided
if [ $# -eq 1 ]; then
  timestamp="$1"
  key_suffix="${POSTGRES_DATABASE}_${timestamp}.sql.gz"
else
  echo "Finding latest backup for ${POSTGRES_DATABASE}..."
  key_suffix=$(aws $aws_args s3 ls "${s3_uri_base}" \
    | grep "^${POSTGRES_DATABASE}_.*\.sql\.gz$" \
    | sort \
    | tail -n1 \
    | awk '{print $4}')
fi

if [ -z "$key_suffix" ]; then
  echo "No backup found for ${POSTGRES_DATABASE}"
  exit 1
fi

echo "Fetching backup from S3: $key_suffix"
aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" "db.sql.gz${ENCRYPTION_PASSWORD:+.enc}"

# decrypt if needed
if [ -n "${ENCRYPTION_PASSWORD:-}" ]; then
  echo "Decrypting backup..."
  openssl enc -d -aes-256-cbc \
    -in db.sql.gz.enc \
    -out db.sql.gz \
    -k "$ENCRYPTION_PASSWORD" || { echo "Decryption failed"; exit 1; }
  rm db.sql.gz.enc
fi

# create database if not exists
psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -tc "SELECT 1 FROM pg_database WHERE datname='$POSTGRES_DATABASE'" | grep -q 1 || \
  psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -c "CREATE DATABASE \"$POSTGRES_DATABASE\""

# restore
echo "Restoring database ${POSTGRES_DATABASE}..."
gunzip -c db.sql.gz | psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" || \
  echo "⚠️ Restore failed for ${POSTGRES_DATABASE}"

rm db.sql.gz
echo "Restore complete."
