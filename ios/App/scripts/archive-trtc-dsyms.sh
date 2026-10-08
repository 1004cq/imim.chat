#!/bin/sh

# Vendor frameworks are precompiled and ship without their symbols registered in
# this local Swift package. Preserve their matching dSYMs in distribution archives.
set -eu

if [ "${ACTION:-}" != "install" ] || [ -z "${DWARF_DSYM_FOLDER_PATH:-}" ]; then
  exit 0
fi

sdk_root="${SRCROOT}/Packages/TRTC/Binaries"
destination="${DWARF_DSYM_FOLDER_PATH}"

# App.xcworkspace links TRTC through CocoaPods. Do not copy dSYMs from the
# retired local Swift package: those binaries can be a different SDK version.
if [ -d "${PODS_ROOT:-}/TXLiteAVSDK_TRTC" ]; then
  echo "TRTC is provided by CocoaPods; skipping local-package dSYM copy"
  exit 0
fi

for framework in TXLiteAVSDK_Professional TXFFmpeg TXSoundTouch; do
  source="${sdk_root}/${framework}.xcframework/ios-arm64_armv7/${framework}.framework.dSYM"
  target="${destination}/${framework}.framework.dSYM"

  if [ ! -d "${source}" ]; then
    echo "error: Missing required TRTC dSYM: ${source}" >&2
    exit 1
  fi

  rm -rf "${target}"
  ditto "${source}" "${target}"
done
