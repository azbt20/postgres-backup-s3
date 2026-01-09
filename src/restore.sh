#! /bin/sh

set -u
set -o pipefail

source ./env.sh

s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}"

export PGPASSWORD=$POSTGRES_PASSWORD

# aws args (endpoint)
if [ "${S3_ENDPOINT:-}" != "" ]; then
  aws_args="--endpoint-url ${S3_ENDPOINT}"
else
  aws_args=""
fi

# ---------------------------
# RESTORE ALL DATABASES
# ---------------------------
if [ "${POSTGRES_BACKUP_ALL:-false}" = "true" ]; then
  echo "POSTGRES_BACKUP_ALL=true → restoring ALL databases"

  # find latest backup if timestamp not provided
  if [ $# -eq 1 ]; then
    key_suffix="$1"
  else
    echo "Finding latest ALL backup..."
    key_suffix=$(
      aws $aws_args s3 ls "${s3_uri_base}" \
        | grep 'all_.*\.sql\.gz' \
        | sort \
        | tail -n 1 \
        | awk '{ print $4 }'
    )
  fi

  if [ -z "$key_suffix" ]; then
    echo "No ALL backup found in S3"
    exit 1
  fi

  echo "Fetching backup from S3: $key_suffix"
  aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" dump.sql.gz${ENCRYPTION_PASSWORD:+.enc}

  # decrypt if needed
  if [ -n "${ENCRYPTION_PASSWORD:-}" ]; then
    echo "Decrypting backup..."
    openssl enc -d -aes-256-cbc \
      -in dump.sql.gz.enc \
      -out dump.sql.gz \
      -k "$ENCRYPTION_PASSWORD" || exit 1
    rm dump.sql.gz.enc
  fi

  echo "Restoring all databases..."
  gunzip -c dump.sql.gz | psql \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" \
    postgres

  rm dump.sql.gz
  echo "Restore ALL complete."
  exit 0
fi

# ---------------------------
# RESTORE SINGLE DATABASE
# ---------------------------

if [ -z "$PASSPHRASE" ]; then
  file_type=".dump"
else
  file_type=".dump.gpg"
fi

if [ $# -eq 1 ]; then
  timestamp="$1"
  key_suffix="${POSTGRES_DATABASE}_${timestamp}${file_type}"
else
  echo "Finding latest backup..."
  key_suffix=$(
    aws $aws_args s3 ls "${s3_uri_base}/${POSTGRES_DATABASE}" \
      | sort \
      | tail -n 1 \
      | awk '{ print $4 }'
  )
fi

echo "Fetching backup from S3..."
aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" "db${file_type}"

if [ -n "$PASSPHRASE" ]; then
  echo "Decrypting backup..."
  gpg --decrypt --batch --passphrase "$PASSPHRASE" db.dump.gpg > db.dump
  rm db.dump.gpg
fi

conn_opts="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $POSTGRES_DATABASE"

echo "Restoring database ${POSTGRES_DATABASE}..."
pg_restore $conn_opts --clean --if-exists db.dump

rm db.dump
echo "Restore complete."
