#!/bin/zsh
# Xcode build phase: copies the vendored libimobiledevice dylibs into
# Contents/Frameworks, signs them with the app's identity, and warns when
# Homebrew has a newer version than the one bundled.

set -euo pipefail

SRC=$SRCROOT/Vendor/libimobiledevice
FRAMEWORKS=$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH
RESOURCES=$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH

if [[ ! -f $SRC/manifest.json ]]; then
    echo "warning: libimobiledevice is not bundled; the libimobiledevice installer will be unavailable. Run Scripts/update-libimobiledevice.sh."
    exit 0
fi

mkdir -p $FRAMEWORKS $RESOURCES
rm -f $FRAMEWORKS/lib*.dylib(N)
cp -f $SRC/lib/*.dylib $FRAMEWORKS/
cp -f $SRC/manifest.json $RESOURCES/libimobiledevice.json

identity=${EXPANDED_CODE_SIGN_IDENTITY:--}
[[ -z $identity ]] && identity=-
for dylib in $FRAMEWORKS/lib*.dylib; do
    codesign --force --sign $identity --timestamp=none --options runtime $dylib
done

# Freshness check against Homebrew, if it is installed on this Mac.
for prefix in /opt/homebrew /usr/local; do
    [[ -d $prefix/opt/libimobiledevice ]] || continue
    for formula in libimobiledevice libimobiledevice-glue libusbmuxd libplist; do
        real=${prefix}/opt/$formula
        [[ -e $real ]] || continue
        installed=${${real:A}:t}
        bundled=$(/usr/bin/plutil -extract versions.$formula raw -o - $SRC/manifest.json 2>/dev/null || echo "")
        if [[ -n $bundled && $installed != $bundled ]]; then
            echo "warning: Bundled $formula is $bundled but Homebrew has $installed. Run Scripts/update-libimobiledevice.sh --no-upgrade to refresh."
        fi
    done
    break
done
