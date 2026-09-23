#!/bin/bash
# Creates a self-signed code-signing identity ("Perch Local Signing") in the login keychain.
# A stable signature lets macOS remember Accessibility / Screen Recording grants across rebuilds.
# The certificate is NOT marked as trusted system-wide; codesign only needs the private key.
set -euo pipefail

NAME="${PERCH_SIGN_IDENTITY:-Perch Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Identity '$NAME' already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:perch >/dev/null 2>&1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P perch -T /usr/bin/codesign >/dev/null
echo "Created signing identity '$NAME'."
