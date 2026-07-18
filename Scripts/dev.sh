#!/usr/bin/env bash
#
# Dev loop: ensure a stable signing identity → rebuild → sign → relaunch.
#
#   ./Scripts/dev.sh                 # build, sign, relaunch (creates the cert on first run)
#   ./Scripts/dev.sh --reset-perms   # also clear stale TCC entries first
#
# About permissions:
#   macOS will NOT let any script GRANT Accessibility / Input Monitoring /
#   Microphone — that database is SIP-protected, and only you can flip the
#   toggles in System Settings. What this script does instead:
#
#     * On first run, creates a local self-signed code-signing certificate
#       (no Apple account needed — it just gives the app a STABLE identity).
#     * Signs every build with that same cert, so once you grant a permission
#       it KEEPS working across rebuilds — no re-prompting.
#     * With --reset-perms, clears stale grants left over from earlier (unsigned
#       or differently-signed) builds so you can re-grant once, cleanly. You only
#       ever need this flag once.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Claude Proxy.app"
BUNDLE_ID="com.zeus12.claude-proxy"
LOG="$HOME/Library/Logs/ClaudeProxy/dictation.log"

SIGN_ID="${CODESIGN_IDENTITY:-Claude Proxy Dev}"
KC="$HOME/Library/Keychains/claude-proxy-signing.keychain-db"
KCPW="claudeproxy"   # password for this dedicated keychain only (not your login)

# Create the self-signed signing identity once. macOS ties Keychain "Always
# Allow" and TCC permissions to the app's signing identity, so a stable cert is
# what lets grants persist across rebuilds. Self-signed is fine — codesign can
# use it even though it's "untrusted" for distribution.
ensure_signing_identity() {
    # If the keychain exists, unlock it and make sure it's in the search list
    # FIRST — otherwise codesign can't see the identity and we'd wrongly think
    # it's missing (and regenerating would change the app's identity, breaking
    # persisted permissions).
    if [ -f "$KC" ]; then
        security unlock-keychain -p "$KCPW" "$KC" 2>/dev/null || true
        local list; list=$(security list-keychains -d user | sed -e 's/"//g' -e 's/^[[:space:]]*//')
        case " $list " in
            *" $KC "*) ;;
            *) security list-keychains -d user -s "$KC" $list ;;
        esac
    fi
    if echo 'int main(){return 0;}' | cc -x c - -o /tmp/.cp_signprobe 2>/dev/null && \
       codesign --force --sign "$SIGN_ID" /tmp/.cp_signprobe 2>/dev/null; then
        rm -f /tmp/.cp_signprobe
        return 0   # identity already usable — reuse the SAME cert
    fi
    rm -f /tmp/.cp_signprobe
    echo "==> Creating local self-signed signing identity '$SIGN_ID' (one-time)"
    local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    security delete-keychain "$KC" 2>/dev/null || true
    security create-keychain -p "$KCPW" "$KC"
    security set-keychain-settings "$KC"
    security unlock-keychain -p "$KCPW" "$KC"
    local existing; existing=$(security list-keychains -d user | sed -e 's/"//g' -e 's/^[[:space:]]*//')
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$KC" $existing
    cat > "$tmp/cs.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $SIGN_ID
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cs.cnf" >/dev/null 2>&1
    # -legacy: macOS `security import` can't read OpenSSL 3's default PKCS#12.
    openssl pkcs12 -export -legacy -out "$tmp/cs.p12" \
        -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -passout pass:"$KCPW" -name "$SIGN_ID" >/dev/null 2>&1
    security import "$tmp/cs.p12" -k "$KC" -P "$KCPW" -A >/dev/null 2>&1
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign:,unsigned: -s -k "$KCPW" "$KC" >/dev/null 2>&1 || true
    echo "    done."
}

ensure_signing_identity

echo "==> Quitting running app"
pkill -9 -f "Claude Proxy" 2>/dev/null || true
pkill -9 -f ClaudeProxy 2>/dev/null || true
sleep 1

if [[ "${1:-}" == "--reset-perms" ]]; then
    echo "==> Resetting stale TCC entries for $BUNDLE_ID (you'll re-grant once)"
    # Service names: Accessibility, ListenEvent (= Input Monitoring), Microphone.
    tccutil reset Accessibility "$BUNDLE_ID" || true
    tccutil reset ListenEvent   "$BUNDLE_ID" || true
    tccutil reset Microphone    "$BUNDLE_ID" || true
fi

echo "==> Building + signing"
./Scripts/package-app.sh 0.2.0-dev

echo "==> Clearing dictation log"
rm -f "$LOG"

echo "==> Launching"
open "$APP"
echo "==> Done. Watch logs with:  tail -f \"$LOG\""
