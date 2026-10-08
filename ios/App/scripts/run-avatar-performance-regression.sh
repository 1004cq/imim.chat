#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:-prefetch}
test_dir=$(mktemp -d /private/tmp/imim-avatar-performance.XXXXXX)
sdk=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path)
flags=(-O -swift-version 5 -target arm64-apple-ios17.6-macabi -sdk "$sdk"
       -F "$sdk/System/iOSSupport/System/Library/Frameworks" -I "$sdk/System/iOSSupport/usr/include")
sources=()
while IFS= read -r path; do sources+=("$path"); done < <(rg --files Packages/Kingfisher/Sources -g '*.swift' -g '!**/*.docc/**' | sort)
# Compile the repository's existing Kingfisher, not a downloaded SDK or stale
# binary. Nothing is added to the App project; only this isolated harness links it.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc "${flags[@]}" \
    -emit-library -emit-module -module-name Kingfisher "${sources[@]}" \
    -emit-module-path "$test_dir/Kingfisher.swiftmodule" -o "$test_dir/libKingfisher.dylib" \
    -Xlinker -install_name -Xlinker '@rpath/libKingfisher.dylib' \
    > "$test_dir/kingfisher-build.log" 2>&1 || { tail -n 40 "$test_dir/kingfisher-build.log"; exit 1; }
case "$mode" in
    prefetch) harness=App/AvatarPrefetchRegression.swift ;;
    cost) harness=scripts/AvatarPresentationCostRegression.swift ;;
    *) exit 2 ;;
esac
{
    sed -n '/^enum AppServer {/,/^}/p' App/APIClient.swift
    cat App/Models.swift App/AvatarStore.swift App/AppLocalization.swift App/DoveTheme.swift \
        App/AvatarImageLoader.swift "$harness"
} | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc "${flags[@]}" \
    -D AVATAR_PREFETCH_TESTS -parse-as-library -I "$test_dir" -L "$test_dir" -lKingfisher \
    -Xlinker -rpath -Xlinker "$test_dir" - -o "$test_dir/AvatarRegression"
namespace=$(uuidgen)
if [[ "$mode" == "prefetch" ]]; then
    "$test_dir/AvatarRegression" --namespace "$namespace"
    # A second process must use disk-only state; no owner cache/defaults are used.
    "$test_dir/AvatarRegression" --namespace "$namespace" --restore
else
    "$test_dir/AvatarRegression" "${@:2}"
fi
