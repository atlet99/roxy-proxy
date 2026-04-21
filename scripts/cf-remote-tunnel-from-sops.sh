#!/usr/bin/env bash
set -euo pipefail

SOPS_KEY_FILE="${SOPS_KEY_FILE:-$HOME/.sops/key.txt}"
ENCRYPTED_FILE="secrets/enc.cloudflare.api.env"
DECRYPTED_FILE="secrets/cloudflare.api.env"

cleanup() {
  rm -f "$DECRYPTED_FILE"
}
trap cleanup EXIT

if [ ! -f "$ENCRYPTED_FILE" ]; then
  echo "Missing $ENCRYPTED_FILE"
  exit 1
fi

SOPS_AGE_KEY_FILE="$SOPS_KEY_FILE" sops --decrypt "$ENCRYPTED_FILE" > "$DECRYPTED_FILE"
chmod 600 "$DECRYPTED_FILE"

set -a
[ -f .env ] && . ./.env
. "$DECRYPTED_FILE"
set +a

./scripts/cf-remote-tunnel-api.sh
