#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
build=${1:?Usage: upload_testflight_free.sh BUILD_NUMBER}
archive="${TMPDIR:-/tmp}/GyroCine-TestFlight-Free-${build}-$(date +%s).xcarchive"
export_dir="${TMPDIR:-/tmp}/GyroCine-TestFlight-Free-${build}-export"

cd "$repo_root"
xcodebuild -project gyro_cine.xcodeproj -scheme GyroCine -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" archive \
  CURRENT_PROJECT_VERSION="$build" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=TESTFLIGHT_FREE \
  GYROCINE_TESTFLIGHT_FREE_BUILD=YES \
  CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES

app_plist="$archive/Products/Applications/GyroCine.app/Info.plist"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_plist") == "$build" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :GyroCineTestFlightFreeBuild' "$app_plist") == YES ]]

xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist artifacts/TestFlightExport.plist -exportPath "$export_dir"
