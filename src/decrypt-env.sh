#!/bin/sh
# Decrypt AZ$ encrypted environment variables using AES-256-CBC
# Same key as exchange-sdk ConnectionStringProtection

AZ_KEY_HEX="4a7bc1d82e9f5631a40de7825cf3196b8d42b5701ea9c63f5487d02ce1964fb3"

decrypt_value() {
  local raw=$(echo "$1" | sed 's/^AZ\$//')
  local tmpfile=$(mktemp)
  printf '%s' "$raw" | base64 -d > "$tmpfile"
  local iv=$(dd if="$tmpfile" bs=1 count=16 2>/dev/null | xxd -p | tr -d '\n')
  local cipherfile=$(mktemp)
  dd if="$tmpfile" bs=1 skip=16 2>/dev/null > "$cipherfile"
  rm -f "$tmpfile"
  openssl enc -aes-256-cbc -d -K "$AZ_KEY_HEX" -iv "$iv" -in "$cipherfile" 2>/dev/null
  local rc=$?
  rm -f "$cipherfile"
  return $rc
}

# Decrypt all AZ$ prefixed env vars
for var in $(env | grep '=AZ\$' | cut -d= -f1); do
  val=$(printenv "$var")
  decrypted=$(decrypt_value "$val")
  if [ $? -eq 0 ] && [ -n "$decrypted" ]; then
    export "$var=$decrypted"
    echo "Decrypted: $var"
  else
    echo "Warning: failed to decrypt $var"
  fi
done

# Execute original command
exec "$@"
