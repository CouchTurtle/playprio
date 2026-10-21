#!/usr/bin/env bash
#
# Creates a self-signed code-signing identity "PlayPrio Local Signing" in your login
# keychain. build.sh signs with it automatically when it exists. macOS then ties the
# Accessibility grant to this certificate instead of to each build's hash, so you grant
# it once and it survives every rebuild.
#
# The certificate is only used to sign PlayPrio on this Mac; it is not trusted for
# anything else. Remove it any time in Keychain Access (search "PlayPrio").
set -euo pipefail

NAME="PlayPrio Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl # Apple's LibreSSL writes .p12 files `security import` can read

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout pass:playprio
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P playprio -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a keychain prompt at every build (asks for your login
# password once, here).
echo "Your login password, so builds can sign without asking each time:"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$NAME" "$KEYCHAIN" >/dev/null

echo "Created \"$NAME\". Next: ./build.sh install, then allow PlayPrio under Accessibility one last time."
