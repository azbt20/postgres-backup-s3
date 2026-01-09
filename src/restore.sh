#! /bin/sh
set -eo pipefail

### Checks
for v in S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET POSTGRES_HOST POSTGRES_USER POSTGRES_PASSWORD; do
  eval val=\$$v
  if [ "$val" = "**None**" ] || [ -z "$val" ]; then
    echo "You need to set $v"
    exit 1
  fi
done

if [ "${POSTGRES_DATABASE}" = "**None**" ] && [ "${POSTGRES_BACKUP_ALL}" != "true" ]; then
  echo "Set POSTGRES_DATABASE or POSTGRES_BACKUP_ALL=true"
  exit 1
fi

### AWS
export AWS_ACCESS_KEY_ID=$S3_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$S3_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=$S3_REGION

if [ "${S3_ENDPOINT}" != "**None**" ] && [ -n "${S3_ENDPOINT}" ]; then
  AWS_ARGS="--endpoint-url ${S3_ENDPOINT}"
else
  AWS_ARGS=""
fi

### Postgres
export PGPASSWORD=$POSTGRES_PASSWORD
POSTGRES_HOST_OPTS="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER"

### Normalize S3_PREFIX
S3_PREFIX="${S3_PREFIX#/}"
S3_PREFIX="${S3_PREFIX%/}"

if [ -n "$S3_PREFIX" ]; then
  S3_URI_BASE="s3://${S3_BUCKET}/${S3_PREFIX}"
else
  S3_URI_BASE="s3://${S3_BUCKET}"
fi

### DB list
if [ "${POSTGRES_BACKUP_ALL}" = "true" ]; then
  echo "Restoring all accessible databases..."
  DB_LIST=$(psql $POSTGRES_HOST_OPTS -d postgres -Atc "
    SELECT datname FROM pg_database
    WHERE datallowconn AND datistemplate = false AND datname <> 'postgres'
  ")
else
  DB_LIST=$(echo "$POSTGRES_DATABASE" | tr ',' ' ')
fi

### Restore loop
for DB in $DB_LIST; do
  echo "---------------------------------------"
  echo "Restoring database: $DB"

  BACKUP_KEY=$(aws $AWS_ARGS s3 ls "$S3_URI_BASE/" \
    | awk '{print $4}' \
    | grep "^${DB}_" \
    | sort \
    | tail -n1)

  if [ -z "$BACKUP_KEY" ]; then
    echo "⚠️  No backup found for $DB, skipping"
    continue
  fi

  echo "Using backup: $BACKUP_KEY"

  aws $AWS_ARGS s3 cp "$S3_URI_BASE/$BACKUP_KEY" dump.sql.gz

  if echo "$BACKUP_KEY" | grep -q '\.enc$'; then
    if [ "${ENCRYPTION_PASSWORD}" = "**None**" ] || [ -z "$ENCRYPTION_PASSWORD" ]; then
      echo "Encrypted backup but ENCRYPTION_PASSWORD not set"
      exit 1
    fi
    echo "Decrypting backup"
    openssl enc -d -aes-256-cbc \
      -in dump.sql.gz \
      -out dump.sql \
      -k "$ENCRYPTION_PASSWORD"
  else
    gunzip -c dump.sql.gz > dump.sql
  fi

  echo "Restoring into $DB"
  echo "Dropping database $DB"
  psql $POSTGRES_HOST_OPTS -d postgres -c "DROP DATABASE IF EXISTS \"$DB\";"
  
  echo "Creating database $DB"
  psql $POSTGRES_HOST_OPTS -d postgres -c "CREATE DATABASE \"$DB\";"
  psql $POSTGRES_HOST_OPTS -d "$DB" < dump.sql

  rm -f dump.sql dump.sql.gz
  echo "✅ $DB restored"
done

echo "Restore complete."
