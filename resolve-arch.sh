#!/bin/bash
# Print the Volumio architecture id: arm | armv7 | armv8 | x64
#
# Shared by install.sh, run_peppymeter.sh and index.js so all of them agree.
#
# /etc/os-release is Volumio's source for VOLUMIO_ARCH, but it is not guaranteed:
# on Volumio 4 the root filesystem is an overlay and /etc/os-release resolves to
# /usr/lib/os-release inside it, so a distro package upgrade (base-files, for
# example) can replace it with the stock Debian file. When that happens every
# VOLUMIO_* key disappears and PeppyMeter stops working until the original file
# is restored by hand.
#
# Probe the other Volumio copies first, then derive the value from the userspace
# ABI. `uname -m` alone is deliberately NOT used: a 64-bit kernel commonly runs a
# 32-bit userland (arm_64bit=0 on Pi) and would select the incompatible armv8
# libraries, which fail to load with "wrong ELF class: ELF64".
#
# Every 32-bit ARM userland maps to "arm". The plugin also ships an "armv7"
# directory, but Volumio reports "arm" for these devices, so "arm" is the value
# a 32-bit device would have had from os-release.
#
# Prints nothing when the architecture cannot be determined; callers keep their
# existing hard error in that case.
#
# Usage: resolve-arch.sh [os-release-file ...]

set -u

arch_supported() {
  case "$1" in
    arm|armv7|armv8|x64) return 0 ;;
  esac
  return 1
}

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=(/etc/os-release /static/usr/lib/os-release /usr/lib/os-release)
fi

for f in "${files[@]}"; do
  [ -r "$f" ] || continue
  value=$(sed -n 's/^VOLUMIO_ARCH=//p' "$f" 2>/dev/null | head -n1 | tr -d "\"' \t\r\n")
  if arch_supported "$value"; then
    printf '%s\n' "$value"
    exit 0
  fi
done

bits=$(getconf LONG_BIT 2>/dev/null)
case "$(uname -m 2>/dev/null)" in
  x86_64|amd64)
    [ "$bits" = "64" ] && printf '%s\n' x64
    ;;
  aarch64|arm64)
    if [ "$bits" = "64" ]; then printf '%s\n' armv8; else printf '%s\n' arm; fi
    ;;
  armv7l|armv6l)
    printf '%s\n' arm
    ;;
esac

exit 0
