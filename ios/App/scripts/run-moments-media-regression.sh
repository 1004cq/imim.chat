#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-moments-media.XXXXXX)
node - <<'JS'
const fs = require('node:fs'), assert = require('node:assert/strict');
const source = fs.readFileSync('App/DiscoveryView.swift', 'utf8');
const api = fs.readFileSync('App/APIClient.swift', 'utf8');
const feed = api.slice(api.indexOf('func fetchMomentsFeed('), api.indexOf('func fetchMomentsFeed(') + 1800);
assert.ok(!feed.includes('MomentMediaTypeResolver.shared.isVideo'));
assert.ok(!/\bAsyncImage\s*\(/.test(source));
const poster = source.slice(source.indexOf('private struct MomentVideoPosterProvider'), source.indexOf('private actor MomentVideoAssetCache'));
assert.ok(poster.includes('cachedFile(for:'));
assert.ok(!poster.includes('download(for:') && !poster.includes('data(for:'));
assert.ok(source.includes('ProxySession.shared.download(for: $0)'));
assert.ok(source.includes('try await transport(request)'));
assert.ok(source.includes('currentPhase(url: url, owner: owner, pixels: pixels)'));
assert.ok(source.includes('.onDisappear { model.reset() }'));
assert.ok(source.includes('Task(priority: .utility)'));
console.log('PASS: feed has no sequential HEAD loop; images cached; poster uses local files only; Proxy transport and identity/release source guards (not UI runtime evidence)');
JS
{
    printf 'import Foundation\nimport CryptoKit\n'
    sed -n '/^struct MomentMediaItem:/,/^actor MomentMediaTypeResolver/ p' App/APIClient.swift | sed '$d'
    sed -n '/^actor MomentMediaTypeResolver/,/^struct RemoteMessageExtra/ p' App/APIClient.swift | sed '$d'
    sed -n '/^\/\/ MARK: - Moments media policy and scheduler/,/^\/\/ MARK: - End Moments media policy and scheduler/p' App/DiscoveryView.swift
    cat scripts/MomentsMediaRegression.swift
} | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
    -O -swift-version 6 -strict-concurrency=complete -parse-as-library - \
    -o "$test_dir/MomentsMediaRegression"
"$test_dir/MomentsMediaRegression"
printf 'Harness artifacts: %s\n' "$test_dir"
