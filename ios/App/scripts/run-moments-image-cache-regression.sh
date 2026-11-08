#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-moments-cache.XXXXXX)
sdk=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path)
flags=(-O -swift-version 5 -target arm64-apple-ios17.6-macabi -sdk "$sdk"
       -F "$sdk/System/iOSSupport/System/Library/Frameworks" -I "$sdk/System/iOSSupport/usr/include")
sources=()
while IFS= read -r path; do sources+=("$path"); done < <(rg --files Packages/Kingfisher/Sources -g '*.swift' -g '!**/*.docc/**' | sort)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc "${flags[@]}" \
    -emit-library -emit-module -module-name Kingfisher "${sources[@]}" \
    -emit-module-path "$test_dir/Kingfisher.swiftmodule" -o "$test_dir/libKingfisher.dylib" \
    -Xlinker -install_name -Xlinker '@rpath/libKingfisher.dylib' \
    > "$test_dir/kingfisher-build.log" 2>&1 || { tail -n 40 "$test_dir/kingfisher-build.log"; exit 1; }
{
    printf 'import Foundation\nimport CryptoKit\nimport UIKit\nimport SwiftUI\nimport Kingfisher\n'
    sed -n '/^struct MomentMediaItem:/,/^actor MomentMediaTypeResolver/ p' App/APIClient.swift | sed '$d'
    sed -n '/^\/\/ MARK: - Moments media policy and scheduler/,/^\/\/ MARK: - End Moments media policy and scheduler/p' App/DiscoveryView.swift
    sed -n '/^private struct MomentImageProvider:/,/^private struct MomentCachedImage/ p' App/DiscoveryView.swift | sed '$d'
    cat scripts/MomentsImageCacheRegression.swift
} | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc "${flags[@]}" \
    -D MOMENTS_MEDIA_TESTS -parse-as-library -I "$test_dir" -L "$test_dir" -lKingfisher \
    -Xlinker -rpath -Xlinker "$test_dir" - -o "$test_dir/MomentsImageCacheRegression"
namespace=$(uuidgen)
"$test_dir/MomentsImageCacheRegression" "$namespace"
"$test_dir/MomentsImageCacheRegression" "$namespace" --restore
printf 'Cache harness artifacts: %s\n' "$test_dir"
