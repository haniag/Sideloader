#!/bin/zsh
# Exports an Xcode archive with Developer ID signing, notarizes it with Apple,
# staples the ticket, and leaves the app in "Sideloader <date>/" in the project folder.
#
# Runs automatically after Product > Archive (the Sideloader scheme's Archive
# post-action). Build phases can't do this: they run before the app is signed.
#
# One-time setup, which stores your Apple ID's app-specific password in the keychain:
#   xcrun notarytool store-credentials Sideloader-notary --apple-id <you@example.com> --team-id <TEAMID>
#
# Usage: Scripts/notarize.sh [path/to/Sideloader.xcarchive]
#   NOTARY_PROFILE     keychain profile name (default: Sideloader-notary)
#   NOTARIZE_DRY_RUN=1 export and sign only; don't send anything to Apple

set -euo pipefail

ROOT=${0:A:h:h}
ARCHIVE=${1:-${ARCHIVE_PATH:-}}
PROFILE=${NOTARY_PROFILE:-Sideloader-notary}
LOG=$HOME/Library/Logs/Sideloader-notarize.log

# Xcode hides post-action output, so keep a log and report through notifications.
if [[ ! -t 1 ]]; then
    exec >$LOG 2>&1
fi

notify() {
    echo "==> $1"
    [[ -t 1 ]] || osascript -e "display notification \"$1\" with title \"Sideloader notarization\"" >/dev/null 2>&1 || true
}
fail() {
    notify "Failed: $1 (see ${LOG/#$HOME/~})"
    exit 1
}

[[ -d $ARCHIVE ]] || fail "no archive at '$ARCHIVE'"

WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT

cat > $WORK/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Exporting $ARCHIVE with Developer ID signing"
xcodebuild -exportArchive -archivePath $ARCHIVE \
    -exportOptionsPlist $WORK/ExportOptions.plist -exportPath $WORK/export \
    || fail "Developer ID export"
APP=($WORK/export/*.app(N))
(( $#APP == 1 )) || fail "export produced no app"
APP=$APP[1]
codesign --verify --deep --strict $APP || fail "signature check"

if [[ -n ${NOTARIZE_DRY_RUN:-} ]]; then
    codesign -dv $APP 2>&1 | grep -E "Authority|flags|TeamIdentifier" || true
    notify "Dry run: exported and signed, nothing sent to Apple"
    exit 0
fi

echo "==> Submitting to Apple (profile: $PROFILE)"
ditto -c -k --keepParent $APP $WORK/upload.zip
xcrun notarytool submit $WORK/upload.zip --keychain-profile $PROFILE --wait 2>&1 | tee $WORK/notary.txt || true
if ! grep -q "status: Accepted" $WORK/notary.txt; then
    if grep -qiE "no keychain password item|profile" $WORK/notary.txt; then
        fail "no '$PROFILE' credentials; run the store-credentials command at the top of Scripts/notarize.sh"
    fi
    id=$(awk '/^ *id:/ {print $2; exit}' $WORK/notary.txt)
    [[ -n $id ]] && xcrun notarytool log $id --keychain-profile $PROFILE || true
    fail "Apple didn't accept the app"
fi

xcrun stapler staple $APP || fail "stapling"

DEST="$ROOT/Sideloader $(date '+%Y-%m-%d %H-%M-%S')"
mkdir -p $DEST
ditto $APP $DEST/${APP:t}
spctl --assess --type execute -vv $DEST/${APP:t} || true
notify "Notarized: ${DEST:t}/${APP:t}"
[[ -t 1 ]] || open -R $DEST/${APP:t}
