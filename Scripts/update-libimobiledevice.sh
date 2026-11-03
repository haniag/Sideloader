#!/bin/zsh
# Refreshes the libimobiledevice copy bundled with Sideloader.
#
# Upgrades the Homebrew formulae (unless --no-upgrade), then copies
# libimobiledevice and every Homebrew dylib it depends on into
# Vendor/libimobiledevice/lib, rewriting install names to @rpath so the
# app can load them from Contents/Frameworks on a Mac without Homebrew.
#
# Usage: Scripts/update-libimobiledevice.sh [--no-upgrade]

set -euo pipefail

ROOT=${0:A:h:h}
DEST=$ROOT/Vendor/libimobiledevice
FORMULAE=(libimobiledevice libimobiledevice-glue libusbmuxd libplist)

BREW=$(command -v brew || true)
[[ -z $BREW && -x /opt/homebrew/bin/brew ]] && BREW=/opt/homebrew/bin/brew
[[ -z $BREW && -x /usr/local/bin/brew ]] && BREW=/usr/local/bin/brew
if [[ -z $BREW ]]; then
    echo "error: Homebrew is required to refresh libimobiledevice (https://brew.sh)" >&2
    exit 1
fi
PREFIX=$($BREW --prefix)

if [[ ${1:-} != --no-upgrade ]]; then
    echo "==> Updating Homebrew"
    $BREW update --quiet
    for formula in $FORMULAE; do
        if $BREW list --versions $formula >/dev/null; then
            $BREW upgrade $formula || true
        else
            $BREW install $formula
        fi
    done
fi

ENTRY=$PREFIX/opt/libimobiledevice/lib/libimobiledevice-1.0.dylib
[[ -e $ENTRY ]] || { echo "error: $ENTRY not found" >&2; exit 1; }

rm -rf $DEST/lib
mkdir -p $DEST/lib

# Homebrew dylib references we must bundle (anything under the Homebrew prefix).
homebrew_deps() {
    otool -L $1 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -E "^($PREFIX|/opt/homebrew|/usr/local)/" || true
}

# Formula version, taken from the Cellar path a dylib resolves to.
formula_version() {
    local real=${1:A}
    [[ $real =~ /Cellar/([^/]+)/([^/]+)/ ]] && echo "$match[1] $match[2]"
}

typeset -A copied versions
queue=($ENTRY)
while (( $#queue )); do
    src=$queue[1]
    shift queue
    # Use the install name's file name so references from other dylibs match.
    name=${$(otool -D $src 2>/dev/null | tail -n 1):t}
    [[ -n ${copied[$name]:-} ]] && continue
    copied[$name]=1

    dst=$DEST/lib/$name
    cp ${src:A} $dst
    chmod u+w $dst
    install_name_tool -id @rpath/$name $dst 2>/dev/null
    # Let each dylib find its siblings when loaded with dlopen.
    install_name_tool -add_rpath @loader_path $dst 2>/dev/null || true

    for dep in $(homebrew_deps $dst); do
        install_name_tool -change $dep @rpath/${dep:t} $dst 2>/dev/null
        queue+=($dep)
    done
    codesign --force --sign - $dst 2>/dev/null

    if fv=$(formula_version $src); then
        versions[${fv%% *}]=${fv#* }
    fi
    echo "    $name"
done

lib_file() { ls $DEST/lib | grep -E "^${1//./\\.}[.0-9]*\.dylib$" | head -n 1; }
imd_file=$(lib_file libimobiledevice-1.0)
plist_file=$(lib_file libplist-2.0)
min_os=$(vtool -show-build $DEST/lib/$imd_file 2>/dev/null | awk '/minos/ && !found {print $2; found = 1}')
archs=$(lipo -archs $DEST/lib/$imd_file 2>/dev/null)

{
    echo "{"
    echo "  \"updated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"libimobiledeviceFile\": \"$imd_file\","
    echo "  \"libplistFile\": \"$plist_file\","
    echo "  \"minimumMacOS\": \"$min_os\","
    echo "  \"architectures\": \"$archs\","
    echo "  \"versions\": {"
    keys=(${(ok)versions})
    for (( i = 1; i <= $#keys; i++ )); do
        sep=","; (( i == $#keys )) && sep=""
        echo "    \"$keys[$i]\": \"$versions[$keys[$i]]\"$sep"
    done
    echo "  }"
    echo "}"
} > $DEST/manifest.json

echo "==> Bundled libimobiledevice ${versions[libimobiledevice]:-?} ($archs, macOS $min_os+) into ${DEST#$ROOT/}"
