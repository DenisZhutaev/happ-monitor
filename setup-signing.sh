#!/bin/zsh
set -euo pipefail
IDENTITY='Happ Monitor Local Signing'
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo 'Signing certificate already exists. Keeping the existing identity unchanged.'
  exit 0
fi
OPENSSL_BIN="${HAPP_OPENSSL_BIN:-}"
if [[ -z "$OPENSSL_BIN" ]] && command -v brew >/dev/null 2>&1; then
  OPENSSL_PREFIX=$(brew --prefix openssl@3 2>/dev/null || true)
  if [[ -x "$OPENSSL_PREFIX/bin/openssl" ]]; then OPENSSL_BIN="$OPENSSL_PREFIX/bin/openssl"; fi
fi
OPENSSL_BIN="${OPENSSL_BIN:-$(command -v openssl)}"
if [[ "$("$OPENSSL_BIN" version)" != 'OpenSSL 3.'* ]]; then
  echo 'OpenSSL 3 is required. Install openssl@3 or set HAPP_OPENSSL_BIN to its executable.' >&2
  exit 1
fi
STAGING=$(mktemp -d /private/tmp/happ-signing.XXXXXX)
chmod 700 "$STAGING"
trap 'rm -rf "$STAGING"' EXIT
umask 077
"$OPENSSL_BIN" rand -hex 32 > "$STAGING/password"
"$OPENSSL_BIN" req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
  -subj "/CN=$IDENTITY/" \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature' \
  -addext 'extendedKeyUsage=critical,codeSigning' \
  -keyout "$STAGING/key.pem" -out "$STAGING/cert.pem" 2> "$STAGING/generation.log"
"$OPENSSL_BIN" pkcs12 -export -legacy -inkey "$STAGING/key.pem" -in "$STAGING/cert.pem" \
  -name "$IDENTITY" -out "$STAGING/identity.p12" -passout "file:$STAGING/password"
security import "$STAGING/identity.p12" -k "$KEYCHAIN" -P "$(cat "$STAGING/password")" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$STAGING/cert.pem"
echo 'Local code-signing identity configured.'
