#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-moments-bugs.XXXXXX)
source=${1:-App/DiscoveryView.swift}
flags=(-O -swift-version 6 -strict-concurrency=complete -parse-as-library)
if [[ ${MOMENTS_FEED_BASELINE:-0} == 1 ]]; then flags+=(-D FEED_BASELINE); fi
if [[ ${MOMENTS_FEED_BASELINE:-0} != 1 ]]; then
node - <<'JS'
const fs = require('node:fs'), assert = require('node:assert/strict');
const source = fs.readFileSync('App/DiscoveryView.swift', 'utf8');
assert.ok(source.includes('await cacheInvalidation?.value'));
assert.ok(source.includes('handlePlaybackFailure(localURL, generation: generation, owner: playbackOwner)'));
assert.ok(source.includes('MomentVideoAssetCache.shared.invalidate(source, owner: owner, failedFile: failedURL)'));
assert.ok(source.includes('self.generation == generation, self.failedURL != url'));
assert.ok(source.includes('coordinator.reset()'));
console.log('PASS: player failure/retry ordering and stale/dismantled observer source guards (not AVPlayer runtime evidence)');
JS
fi
{
    printf 'import Foundation\nimport CryptoKit\nimport Combine\n'
    sed -n '/^struct MomentMediaItem:/,/^actor MomentMediaTypeResolver/ p' App/APIClient.swift | sed '$d'
    sed -n '/^\/\/ MARK: - Moments media policy and scheduler/,/^\/\/ MARK: - End Moments media policy and scheduler/p' "$source"
    printf '@MainActor\n'
    sed -n '/^private final class MomentsFeedViewModel:/,/^    func toggleLike/ p' "$source" | sed '$d'
    printf '    private func prefetchAvatars(_ items: [MomentFeedItem]) {}\n}\n'
    if [[ ${MOMENTS_FEED_BASELINE:-0} != 1 ]]; then
        sed -n '/^private actor MomentVideoAssetCache/,/^private struct MomentUploadSelection/ p' "$source" | sed '$d'
    fi
    cat scripts/MomentsBugfixRegression.swift
} | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc "${flags[@]}" \
    - -o "$test_dir/MomentsBugfixRegression"
"$test_dir/MomentsBugfixRegression"
printf 'Bug regression artifacts: %s\n' "$test_dir"
