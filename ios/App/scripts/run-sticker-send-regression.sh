#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-sticker-send.XXXXXX)
python3 - "$test_dir/ActualSticker.swift" <<'PY'
from pathlib import Path
import os,sys
vm=Path(os.environ.get('STICKER_VM_SOURCE','App/ChatDetailViewModel.swift')).read_text()
media=Path(os.environ.get('STICKER_MEDIA_SOURCE','App/StickerMedia.swift')).read_text()
api=Path('App/APIClient.swift').read_text()
def declaration(s,marker):
 start=s.index(marker);i=s.index('{',start)+1;depth=1
 while depth:
  if s[i]=='{':depth+=1
  elif s[i]=='}':depth-=1
  i+=1
 return s[start:i]
methods='\n'.join(declaration(vm,m) for m in ['func sendSticker(', 'private func coalesceStickerEcho(', 'func handleSocketMessage(', 'private func apply(', 'private func peerUserId('] if m in vm).replace('UserDefaults.standard','fixtureDefaults')
models=media[media.index('// Mirrors the authenticated'):media.index('// MARK: Sticker playback policy')]
remote=declaration(api,'struct RemoteMessageExtra:')+'\n'+declaration(api,'struct RemoteMessage:')
conversion='extension RemoteMessage {\n'+declaration(api[api.index('extension RemoteMessage {'):],'func toLocalMessage(currentUserId:')+'\n}'
fixture=Path('scripts/StickerSendRegression.swift').read_text()
Path(sys.argv[1]).write_text('import Foundation\nimport SwiftData\n'+models+'\n'+remote+'\n'+conversion+'\n'+fixture.replace('// ACTUAL_METHODS',methods))
PY
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -swift-version 5 -parse-as-library App/Models.swift "$test_dir/ActualSticker.swift" -o "$test_dir/regression"
"$test_dir/regression"
