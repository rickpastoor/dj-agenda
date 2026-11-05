#!/bin/bash
# Bouwt een ondertekende, genotariseerde DJAgenda-<versie>.dmg in build/release.
#
#   scripts/release.sh 0.2            # versie 0.2
#   SKIP_NOTARIZE=1 scripts/release.sh 0.2
#
# Ondertekenen: TEAM_ID (standaard ZCXSU9SYUC) en een "Developer ID Application"-certificaat
# in de keychain.
# Notariseren, één van beide:
#   - NOTARY_PROFILE: een profiel van `xcrun notarytool store-credentials` (lokaal);
#   - NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER: een App Store Connect API-sleutel (CI).
set -euo pipefail

VERSION="${1:?gebruik: scripts/release.sh <versie>}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
TEAM_ID="${TEAM_ID:-ZCXSU9SYUC}"
IDENTITY="Developer ID Application"

cd "$(dirname "$0")/.."
OUT="build/release"
ARCHIVE="$OUT/DJAgenda.xcarchive"
EXPORT="$OUT/export"
DMG="$OUT/DJAgenda-$VERSION.dmg"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Archief bouwen ($VERSION, build $BUILD_NUMBER)"
xcodebuild archive \
  -project DJAgenda.xcodeproj \
  -scheme DJAgenda \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath build/release-dd \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ARCHS=arm64 \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | (command -v xcbeautify >/dev/null && xcbeautify || cat)

echo "==> Exporteren (Developer ID)"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist"

APP="$EXPORT/DJAgenda.app"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> DMG maken"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DJ Agenda" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ "${SKIP_NOTARIZE:-}" == 1 ]]; then
  echo "==> Notariseren overgeslagen"
else
  echo "==> Notariseren"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  else
    echo "Zet NOTARY_PROFILE of NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER (of SKIP_NOTARIZE=1)." >&2
    exit 1
  fi
  xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --timeout 30m
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> Klaar: $DMG"
