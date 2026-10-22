#!/usr/bin/env bash
#
# build.sh — compile the SwiftPM executable target and assemble a proper
# macOS .app bundle around it.
#
# Stable signing strategy: on first run we create a self-signed code-
# signing certificate "AutoSwitcher Local Dev" in the user's login
# keychain. Every subsequent build signs with the SAME identity. macOS
# TCC sees a stable signing authority across rebuilds, so Accessibility
# and Input Monitoring approvals persist (this is the trick RuSwitcher
# uses with a real Developer ID — comment in their build_app.sh:
# "разрешения macOS привязаны к подписи").
#
# Usage:
#   ./build.sh              # release build → ./AutoSwitcher.app
#   ./build.sh debug
#   CLEAN=1 ./build.sh      # wipe .build and rebuild from scratch
#   SIGN=adhoc ./build.sh   # force ad-hoc signing
#   SIGN=stable ./build.sh  # create the identity if missing, then use it
#
set -euo pipefail

CONFIG="${1:-release}"
CLEAN="${CLEAN:-0}"
SIGN="${SIGN:-auto}"                 # auto | adhoc | stable
# Why signing identity matters: TCC (Accessibility / Input Monitoring)
# stores the app's *designated requirement* when the user grants access.
#   ad-hoc      → DR is `cdhash H"…"`: every rebuild is a "new app" and the
#                 permissions have to be granted again after each update.
#   self-signed → DR is `identifier "com.autoswitcher.app" and certificate
#                 leaf = H"…"`: every build signed with the same cert
#                 satisfies it, so grants survive updates.
# auto = use the "AutoSwitcher Local Dev" identity if it is already in the
# keychain (no prompts, nothing created), otherwise fall back to ad-hoc —
# so a fresh clone still builds without touching anyone's keychain.
SIGN_CN="AutoSwitcher Local Dev"

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AutoSwitcher"
BUNDLE="${HERE}/${APP_NAME}.app"
RES_SRC="${HERE}/Sources/AutoSwitcher/Resources"
PLIST_SRC="${RES_SRC}/Info.plist"
ICONSET_SRC="${RES_SRC}/AppIcon.iconset"
ENTITLEMENTS="${HERE}/AutoSwitcher.entitlements"

cd "${HERE}"

# ---------- 1. Optional clean ----------------------
# (No blanket `touch` of sources here: bumping every mtime forced SwiftPM
# into a full rebuild on every run. Incremental builds are fine.)
if [[ "${CLEAN}" == "1" ]]; then
    echo "==> CLEAN=1 — wiping .build"
    rm -rf .build
fi

# ---------- 2. Build ------------------------------
echo "==> Building (${CONFIG})…"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)"
EXE="${BIN_PATH}/${APP_NAME}"
if [[ ! -x "${EXE}" ]]; then
    echo "error: executable not found at ${EXE}" >&2
    exit 1
fi

# ---------- 3. Assemble bundle --------------------
# IMPORTANT: assemble and sign in a temp dir OUTSIDE the project folder.
# If the project lives on an iCloud-synced path (Desktop/Documents), the
# file provider re-attaches FinderInfo xattrs asynchronously and codesign
# fails with "resource fork, Finder information, or similar detritus not
# allowed". A /tmp staging dir sidesteps that race entirely.
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/autoswitcher-build.XXXXXX")"
trap 'rm -rf "${STAGING}"' EXIT
STAGE_BUNDLE="${STAGING}/${APP_NAME}.app"

echo "==> Assembling ${STAGE_BUNDLE}"
mkdir -p "${STAGE_BUNDLE}/Contents/MacOS"
mkdir -p "${STAGE_BUNDLE}/Contents/Resources"
cp "${EXE}" "${STAGE_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${PLIST_SRC}" "${STAGE_BUNDLE}/Contents/Info.plist"

if [[ -d "${ICONSET_SRC}" ]]; then
    echo "==> Generating AppIcon.icns"
    iconutil -c icns -o "${STAGE_BUNDLE}/Contents/Resources/AppIcon.icns" "${ICONSET_SRC}"
fi

# ---------- 4. Cleanup before signing -------------
echo "==> Stripping xattrs / Finder detritus"
xattr -cr "${STAGE_BUNDLE}" 2>/dev/null || true
find "${STAGE_BUNDLE}" -name '.DS_Store' -delete 2>/dev/null || true
find "${STAGE_BUNDLE}" -name '._*'       -delete 2>/dev/null || true

# ---------- 5. Stable self-signed identity --------
ensure_self_signed_cert() {
    if security find-identity -v -p codesigning login.keychain 2>/dev/null \
       | grep -F -q "${SIGN_CN}"; then
        return 0
    fi

    echo "==> First run: creating self-signed code-signing certificate '${SIGN_CN}'"
    echo "    (this is one-time; it lives in your login keychain forever after)"

    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN

    # Cert config — Code Signing extension is the magic bit codesign looks for.
    cat > "${tmp}/cert.conf" <<EOF
[req]
distinguished_name = dn
prompt             = no
x509_extensions    = v3
[dn]
CN = ${SIGN_CN}
[v3]
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
EOF

    openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
        -config "${tmp}/cert.conf" \
        -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem" >/dev/null 2>&1

    # Combine into a PKCS12 (codesign needs a private key paired with the cert).
    # OpenSSL 3.x defaults to a MAC algorithm that macOS Security framework
    # cannot import — `-legacy` falls back to OpenSSL 1.x-compatible output.
    # If our openssl doesn't support `-legacy` (older builds), retry without.
    if ! openssl pkcs12 -export -inkey "${tmp}/key.pem" -in "${tmp}/cert.pem" \
            -out "${tmp}/identity.p12" -passout pass:autoswitcher \
            -name "${SIGN_CN}" -legacy 2>/dev/null; then
        openssl pkcs12 -export -inkey "${tmp}/key.pem" -in "${tmp}/cert.pem" \
            -out "${tmp}/identity.p12" -passout pass:autoswitcher \
            -name "${SIGN_CN}" \
            -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES >/dev/null 2>&1
    fi

    # Import into the user's login keychain. -T codesign whitelists codesign
    # to use the key. (On macOS 10.12+ that alone isn't enough — we also have
    # to put codesign in the key's "partition list" below.)
    security import "${tmp}/identity.p12" \
        -k "${HOME}/Library/Keychains/login.keychain-db" \
        -P autoswitcher \
        -T /usr/bin/codesign >/dev/null

    # macOS 10.12+ keychain partitioning: the imported private key gets a
    # "partition list" that defaults to only allow the keychain owner. Without
    # this, codesign triggers a GUI password prompt on every build. Adding
    # apple-tool:,apple:,codesign: makes codesign able to use the key silently.
    security set-key-partition-list \
        -S "apple-tool:,apple:,codesign:" \
        -k "$(security default-keychain -d user | tr -d ' "\n')" \
        "${HOME}/Library/Keychains/login.keychain-db" 2>/dev/null || \
    security set-key-partition-list \
        -S "apple-tool:,apple:,codesign:" \
        -s -k "" \
        "${HOME}/Library/Keychains/login.keychain-db" 2>/dev/null || true

    # Mark the certificate as trusted for codeSigning so codesign doesn't
    # complain about "untrusted root".
    security add-trusted-cert -p codeSign \
        -k "${HOME}/Library/Keychains/login.keychain-db" \
        "${tmp}/cert.pem" 2>/dev/null || true

    echo "    Done. Future builds reuse this identity."
}

# Entitlements file — explicitly disable sandbox so we can install a tap.
if [[ ! -f "${ENTITLEMENTS}" ]]; then
    cat > "${ENTITLEMENTS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
EOF
fi

has_identity() {
    security find-identity -v -p codesigning 2>/dev/null | grep -F -q "\"${SIGN_CN}\""
}

if [[ "${SIGN}" == "auto" ]]; then
    if has_identity; then SIGN="stable"; else SIGN="adhoc"; fi
fi

if [[ "${SIGN}" == "stable" ]]; then
    ensure_self_signed_cert
    echo "==> Code-signing with '${SIGN_CN}'"
    codesign --force --deep \
        --sign "${SIGN_CN}" \
        --entitlements "${ENTITLEMENTS}" \
        "${STAGE_BUNDLE}"
else
    echo "==> Ad-hoc code-signing"
    codesign --force --deep --sign - "${STAGE_BUNDLE}"
fi

# ---------- 6. Move the signed bundle into place ---
rm -rf "${BUNDLE}"
ditto "${STAGE_BUNDLE}" "${BUNDLE}"
touch "${BUNDLE}"

echo
echo "==> Done: ${BUNDLE}"
echo "Tip: drag ${APP_NAME}.app to /Applications, launch once, and grant"
echo "     Accessibility access in System Settings → Privacy & Security."
