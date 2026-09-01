# MouseBinder tasks. Run `just` to list them.

APP := "MouseBinder.app"
BUNDLE_ID := "io.rlew.mousebinder"
NOTARY_PROFILE := "mousebinder-notary"
VOLNAME := "MouseBinder"

default:
    @just --list

# Build and assemble MouseBinder.app (dev-signed; config: release|debug)
build config="release":
    #!/usr/bin/env bash
    # The stable CFBundleIdentifier + a stable signature keep the TCC
    # (Accessibility / Input Monitoring) grant alive across rebuilds — otherwise
    # every rebuild would change the binary's identity and you'd re-grant each time.
    set -euo pipefail

    echo "==> swift build -c {{config}}"
    swift build -c "{{config}}"
    BIN="$(swift build -c "{{config}}" --show-bin-path)/MouseBinder"

    echo "==> assembling {{APP}}"
    rm -rf "{{APP}}"
    mkdir -p "{{APP}}/Contents/MacOS" "{{APP}}/Contents/Resources"
    cp "$BIN" "{{APP}}/Contents/MacOS/MouseBinder"
    cp Resources/Info.plist "{{APP}}/Contents/Info.plist"
    if [ -f Resources/AppIcon.icns ]; then
        cp Resources/AppIcon.icns "{{APP}}/Contents/Resources/AppIcon.icns"
    fi

    # Signing preference, best TCC behaviour first:
    #   1. Developer ID — same identity family as `just release`, so dev and release
    #      builds share one TCC (Accessibility) row and grants survive switching
    #      between them. TCC keeps ONE row per bundle id, pinned to whichever
    #      signature last prompted; two differently-signed copies fight over it.
    #   2. "MouseBinder Dev" (local self-signed; `just dev-cert`) — grant survives
    #      rebuilds, but not switching to/from a Developer ID copy.
    #   3. Ad-hoc — grant is pinned to the cdhash, dies every rebuild.
    IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
    if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning | grep -qF '"MouseBinder Dev"'; then
        IDENTITY="MouseBinder Dev"
    fi
    if [ -n "$IDENTITY" ]; then
        echo "==> signing with: $IDENTITY"
        codesign --force --sign "$IDENTITY" --identifier "{{BUNDLE_ID}}" "{{APP}}"
    else
        echo "==> ad-hoc signing (no signing cert found — grant won't survive rebuilds)"
        codesign --force --sign - --identifier "{{BUNDLE_ID}}" "{{APP}}"
    fi

    echo "==> done: {{APP}}"
    echo "    Run it with:  open {{APP}}"

    # Two live copies both tap .otherMouseDown and double-fire every binding
    # (Mission Control opens and instantly closes — looks like a broken binding).
    RUNNING="$(pgrep -fl 'MouseBinder\.app/Contents/MacOS/MouseBinder' | grep -v "$PWD" || true)"
    if [ -n "$RUNNING" ]; then
        echo ""
        echo "warning: MouseBinder is already running from another path — quit it"
        echo "before launching this build, or every binding fires twice:"
        echo "$RUNNING"
    fi

# Build, Developer-ID-sign, notarize, and staple a distributable zip + DMG in dist/
release:
    #!/usr/bin/env bash
    # One-time setup required first:
    #   1. A "Developer ID Application" certificate in the login keychain
    #      (Xcode -> Settings -> Accounts -> Manage Certificates -> + ).
    #   2. Notarization credentials stored under the keychain profile:
    #      xcrun notarytool store-credentials {{NOTARY_PROFILE}} \
    #          --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-pw>
    set -euo pipefail

    # Resolve the Developer ID identity from the keychain.
    IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
    if [ -z "$IDENTITY" ]; then
        echo "error: no 'Developer ID Application' certificate in keychain." >&2
        echo "Create one in Xcode -> Settings -> Accounts -> Manage Certificates." >&2
        exit 1
    fi

    echo "==> swift build -c release"
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/MouseBinder"

    echo "==> assembling {{APP}}"
    rm -rf "{{APP}}"
    mkdir -p "{{APP}}/Contents/MacOS" "{{APP}}/Contents/Resources"
    cp "$BIN" "{{APP}}/Contents/MacOS/MouseBinder"
    cp Resources/Info.plist "{{APP}}/Contents/Info.plist"
    [ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "{{APP}}/Contents/Resources/AppIcon.icns"

    echo "==> signing with: $IDENTITY"
    # Hardened runtime + secure timestamp are both required by notarization.
    codesign --force --sign "$IDENTITY" --identifier "{{BUNDLE_ID}}" \
        --options runtime --timestamp "{{APP}}"
    codesign --verify --strict --verbose=2 "{{APP}}"

    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
    ZIP="dist/MouseBinder-$VERSION.zip"

    echo "==> zipping for notarization"
    mkdir -p dist
    rm -f "$ZIP"
    # ditto preserves the resource forks/permissions notarization expects.
    ditto -c -k --keepParent "{{APP}}" "$ZIP"

    echo "==> submitting to Apple notary service (waits for verdict)"
    xcrun notarytool submit "$ZIP" --keychain-profile "{{NOTARY_PROFILE}}" --wait

    echo "==> stapling ticket to {{APP}}"
    xcrun stapler staple "{{APP}}"

    # The submitted zip doesn't contain the stapled ticket — rebuild it from the
    # stapled app so offline Gatekeeper checks pass too.
    echo "==> re-zipping stapled app"
    rm -f "$ZIP"
    ditto -c -k --keepParent "{{APP}}" "$ZIP"

    # The DMG is a second distributable of the same stapled app, with an
    # /Applications symlink for drag-install. It needs its own signature and its
    # own notarization ticket: the app's ticket covers the bundle inside, not the
    # disk image Gatekeeper assesses when the user opens the download.
    DMG="dist/MouseBinder-$VERSION.dmg"
    echo "==> building $DMG from the stapled app"
    "{{just_executable()}}" dmg

    echo "==> signing $DMG"
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"

    echo "==> submitting $DMG to Apple notary service (waits for verdict)"
    xcrun notarytool submit "$DMG" --keychain-profile "{{NOTARY_PROFILE}}" --wait

    echo "==> stapling ticket to $DMG"
    xcrun stapler staple "$DMG"

    echo "==> Gatekeeper check"
    spctl --assess --type exec --verbose=2 "{{APP}}"
    xcrun stapler validate "{{APP}}"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    xcrun stapler validate "$DMG"

    echo "==> done: $ZIP"
    echo "          $DMG"

# Package the current MouseBinder.app into dist/MouseBinder-VERSION.dmg (unsigned; `release` signs it)
dmg:
    #!/usr/bin/env bash
    # Plain hdiutil, no create-dmg dependency. The image holds the app next to an
    # /Applications symlink, laid out as the usual drag-to-install window: fixed
    # size, big icons, a background with an arrow between them. Finder stores that
    # layout in the volume's .DS_Store, and only Finder can write one, so the
    # recipe builds a read-write image, has Finder arrange it via AppleScript, then
    # converts to the compressed read-only image that ships. Runs on whatever
    # {{APP}} is present, so it also works on a dev build to check the layout.
    set -euo pipefail

    if [ ! -d "{{APP}}" ]; then
        echo "error: {{APP}} not found — run 'just build' or 'just release' first." >&2
        exit 1
    fi

    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
    DMG="dist/MouseBinder-$VERSION.dmg"

    # Window geometry in Finder points. The background arrow is drawn to match
    # these (see scripts/make-dmg-background.swift), so change them together.
    WIN_W=660; WIN_H=400; ICON=128
    APP_X=180; APPS_X=480; ICON_Y=190

    TMP="$(mktemp -d)"
    MOUNT=""
    cleanup() {
        [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
        rm -rf "$TMP"
    }
    trap cleanup EXIT

    echo "==> staging"
    STAGING="$TMP/staging"
    mkdir -p "$STAGING/.background"
    # ditto keeps the signature, xattrs, and any stapled ticket intact.
    ditto "{{APP}}" "$STAGING/{{APP}}"
    ln -s /Applications "$STAGING/Applications"
    swift scripts/make-dmg-background.swift "$STAGING/.background/background.png" >/dev/null
    # Volume icon: the app icon, shown on the mounted disk in Finder and the Dock.
    cp Resources/AppIcon.icns "$STAGING/.VolumeIcon.icns"

    echo "==> creating read-write image"
    RW="$TMP/rw.dmg"
    hdiutil create -volname "{{VOLNAME}}" -srcfolder "$STAGING" -fs HFS+ \
        -format UDRW -size 64m -ov -quiet "$RW"
    MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" \
        | awk -F'\t' '/\/Volumes\// {print $NF}')"
    SetFile -a C "$MOUNT"   # "has custom icon" flag, so .VolumeIcon.icns is used

    echo "==> laying out the Finder window"
    # Finder opens the image's root at the saved bounds/view/positions. Toolbar
    # and status bar off gives the plain drag-install window rather than a
    # browser window. Needs Automation permission for Finder on first run.
    osascript - "$MOUNT" "$WIN_W" "$WIN_H" "$ICON" "$APP_X" "$APPS_X" "$ICON_Y" <<'EOS'
    on run argv
        set mountPath to item 1 of argv
        set winW to (item 2 of argv) as integer
        set winH to (item 3 of argv) as integer
        set iconSize to (item 4 of argv) as integer
        set appX to (item 5 of argv) as integer
        set appsX to (item 6 of argv) as integer
        set iconY to (item 7 of argv) as integer
        set vol to POSIX file mountPath as alias
        tell application "Finder"
            tell disk (name of vol)
                open
                set win to container window
                set current view of win to icon view
                set toolbar visible of win to false
                set statusbar visible of win to false
                try
                    set pathbar visible of win to false
                end try
                set sidebar width of win to 0
                set bounds of win to {100, 100, 100 + winW, 100 + winH}
                set opts to icon view options of win
                set arrangement of opts to not arranged
                set icon size of opts to iconSize
                set text size of opts to 13
                set label position of opts to bottom
                set shows icon preview of opts to false
                set background picture of opts to file ".background:background.png"
                set position of item "MouseBinder.app" to {appX, iconY}
                set position of item "Applications" to {appsX, iconY}
                -- Park the housekeeping files outside the window for anyone
                -- who has Finder showing hidden files.
                repeat with n in {".background", ".fseventsd", ".VolumeIcon.icns"}
                    try
                        set position of item n to {winW + 200, iconY}
                    end try
                end repeat
                close
                open
                update every item
                delay 1
                close
            end tell
        end tell
    end run
    EOS

    # Finder writes .DS_Store lazily; wait for it before detaching.
    for _ in $(seq 1 20); do
        [ -f "$MOUNT/.DS_Store" ] && break
        sleep 0.5
    done
    if [ ! -f "$MOUNT/.DS_Store" ]; then
        echo "error: Finder did not write .DS_Store — layout would be lost." >&2
        exit 1
    fi
    sync
    hdiutil detach "$MOUNT" -quiet
    MOUNT=""

    echo "==> converting to compressed read-only image"
    mkdir -p dist
    rm -f "$DMG"
    hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG"

    echo "==> done: $DMG"

# Create the local self-signed "MouseBinder Dev" cert so TCC grants survive rebuilds
dev-cert name="MouseBinder Dev":
    #!/usr/bin/env bash
    # Ad-hoc signing (codesign -s -) anchors the TCC grant to the binary's cdhash,
    # which changes every rebuild => you'd re-grant Accessibility each time. Signing
    # with a stable certificate anchors the grant to the cert instead, so you grant
    # once. This cert is local-only and never leaves the machine.
    set -euo pipefail

    CERT_NAME="{{name}}"
    KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

    if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
        echo "Certificate '$CERT_NAME' already present in login keychain — nothing to do."
        exit 0
    fi

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    # Use Apple's LibreSSL, not a Homebrew OpenSSL 3 that produces PKCS#12 bundles
    # `security import` can't MAC-verify.
    OPENSSL=/usr/bin/openssl
    P12_PASS="mousebinder-dev"

    cat > "$TMP/cert.cnf" <<EOF
    [req]
    distinguished_name = dn
    x509_extensions = v3
    prompt = no
    [dn]
    CN = $CERT_NAME
    [v3]
    basicConstraints = critical,CA:false
    keyUsage = critical,digitalSignature
    extendedKeyUsage = critical,codeSigning
    EOF

    echo "==> generating self-signed code-signing cert (10y)"
    "$OPENSSL" req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -days 3650 -nodes -config "$TMP/cert.cnf" >/dev/null 2>&1

    "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -name "$CERT_NAME" -out "$TMP/cert.p12" -passout "pass:$P12_PASS" >/dev/null 2>&1

    echo "==> importing into login keychain (grants codesign access)"
    security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

    echo "==> trusting cert for code signing"
    # User-domain trust (no sudo). May pop a one-time auth dialog.
    security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null \
        || echo "    (trust step skipped — codesign may prompt 'Allow' on first use)"

    echo "==> done. Identities now available to codesign:"
    security find-identity -v -p codesigning | grep -i "$CERT_NAME" || true

# Regenerate Resources/AppIcon.icns from scripts/make-icon.swift
icon:
    #!/usr/bin/env bash
    set -euo pipefail
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    swift scripts/make-icon.swift "$ICONSET" "/tmp/AppIcon-preview.png"
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
    echo "==> wrote Resources/AppIcon.icns (preview: /tmp/AppIcon-preview.png)"
