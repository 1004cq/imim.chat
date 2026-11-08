#!/bin/sh
# Copy genuine vendor symbols only when UUIDs match the actual archived SDK.
set -eu
if [ "${ACTION:-}" != "install" ] || [ -z "${DWARF_DSYM_FOLDER_PATH:-}" ]; then
  exit 0
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python_bin="${PYTHON3:-/usr/bin/python3}"
if [ -d "${PODS_ROOT:-}/TXLiteAVSDK_TRTC" ]; then
  sdk_version=$(sed -n 's/^  - TXLiteAVSDK_TRTC (\([^)]*\)).*/\1/p' "${PODS_ROOT}/Manifest.lock" | head -n 1)
  if [ -z "$sdk_version" ]; then
    echo "error: Cannot determine the installed TRTC SDK version" >&2
    exit 1
  fi
  framework_root="${TRTC_FRAMEWORK_ROOT:-${PODS_ROOT}/TXLiteAVSDK_TRTC/TXLiteAVSDK_TRTC}"
  symbols_root="${TRTC_DSYM_ROOT:-${HOME}/Library/Caches/imim/TRTCSymbols/${sdk_version}}"
  if [ ! -f "${symbols_root}/manifest.json" ] && [ -z "${TRTC_DSYM_ROOT:-}" ]; then
    echo "error: Prepare vendor symbols before archiving: python3 ${script_dir}/trtc-dsyms.py prepare --version ${sdk_version}" >&2
    exit 1
  fi
  set -- --framework TXLiteAVSDK_TRTC --framework TXFFmpeg --framework TXSoundTouch
else
  framework_root="${TRTC_FRAMEWORK_ROOT:-${SRCROOT}/Packages/TRTC/Binaries}"
  symbols_root="${TRTC_DSYM_ROOT:-${framework_root}}"
  set -- --framework TXLiteAVSDK_Professional --framework TXFFmpeg --framework TXSoundTouch
fi
# ARCHS is an Xcode-provided whitespace-separated list; pass each as an argument.
for architecture in ${ARCHS:-arm64}; do
  set -- "$@" --arch "$architecture"
done
"$python_bin" "${script_dir}/trtc-dsyms.py" copy \
  --framework-root "$framework_root" --symbols-root "$symbols_root" \
  --destination "$DWARF_DSYM_FOLDER_PATH" "$@"
