#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-moments-interaction.XXXXXX)
python3 - "$test_dir/ActualMoments.swift" <<'PY'
from pathlib import Path
import sys
import os
s=Path(os.environ.get('MOMENTS_INTERACTION_SOURCE', 'App/DiscoveryView.swift')).read_text()
model=s[s.index('@MainActor\nprivate final class MomentsFeedViewModel:'):s.index('private struct MomentFeedRow:')]
Path(sys.argv[1]).write_text('import Foundation\nimport Combine\n'+model+Path('scripts/MomentsInteractionRegression.swift').read_text())
# Presentation guards complement compiled async model checks; they are not tap tests.
row=s[s.index('private struct MomentFeedRow:'):s.index('private struct MomentMediaGrid:')]
assert '(String) async throws -> Void' in row
send=row[row.index('try await onComment(content)'):]
assert send.index('commentText = ""') < send.index('} catch {')
assert 'isSendingComment || commentText.trimmingCharacters' in row
assert '评论发送失败，请重试' in row
assert row.count('.disabled(isLiking)') == 2
assert 'try? await viewModel.comment' not in s
composer=s[s.index('private struct MomentComposerSheet:'):s.index('private struct MomentCommentSheet:')]
assert 'let draft = content' in composer and 'let selections = selectedItems' in composer
assert 'onSubmit(draft, media)' in composer
assert '.onDisappear { submissionTask?.cancel() }' in composer
assert 'Button("取消") { submissionTask?.cancel(); dismiss() }' in composer
assert composer.count('.disabled(isSubmitting)') >= 2
assert 'MomentImagePipeline.owner == owner' in composer
print('PASS: comment draft/error/in-flight and both like button presentation guards (source only)')
PY
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library "$test_dir/ActualMoments.swift" -o "$test_dir/regression"
"$test_dir/regression"
printf 'Interaction regression artifacts: %s\n' "$test_dir"
