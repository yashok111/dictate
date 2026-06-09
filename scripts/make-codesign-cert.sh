#!/usr/bin/env bash
# Create a self-signed code-signing identity so the `dictate` binary has a STABLE
# TCC identity — Microphone + Accessibility grants then survive rebuilds (a plain
# ad-hoc/linker-signed binary is keyed by cdhash, which changes on every `make`, so
# the grants break each time; see CLAUDE.md gotcha #14).
#
# Run ONCE per machine:  scripts/make-codesign-cert.sh
# Then:  make && cp dictate ~/.local/bin/ && (grant Mic + Accessibility once)
#
# The Makefile auto-signs `dictate` with this identity if it's present (SIGN_ID).
set -euo pipefail
ID="${1:-dictate-codesign}"

if security find-certificate -a -c "$ID" -Z "$HOME/Library/Keychains/login.keychain-db" \
     2>/dev/null | grep -q "^SHA-1 hash:"; then
  echo "✓ codesigning identity '$ID' already exists — nothing to do."
  exit 0
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$tmp/k.pem" -out "$tmp/c.pem" -subj "/CN=$ID" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# OpenSSL 3 needs -legacy for a p12 macOS `security` can import; LibreSSL doesn't have it.
openssl pkcs12 -export -legacy -inkey "$tmp/k.pem" -in "$tmp/c.pem" \
  -out "$tmp/i.p12" -passout pass:dictate -name "$ID" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$tmp/k.pem" -in "$tmp/c.pem" \
       -out "$tmp/i.p12" -passout pass:dictate -name "$ID"

# Grant ONLY /usr/bin/codesign access to the private key (ACL via -T), NOT -A. `-A` lets ANY
# app use the key with no prompt — a malicious binary could then re-sign itself with this
# identity and inherit dictate's Mic/Accessibility TCC grants (the DR is cert-based; gotcha #14).
# Trade-off: the first `make` may pop a one-time keychain prompt — click "Always Allow".
security import "$tmp/i.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P dictate -T /usr/bin/codesign

echo "✓ created self-signed codesigning identity '$ID'."
echo "  next: make && cp dictate ~/.local/bin/dictate"
echo "        then grant Microphone + Accessibility to ~/.local/bin/dictate ONCE"
echo "        (the grants now survive future rebuilds)."
