#!/bin/bash
# Test script for Volumio architecture detection.
#
# resolve-arch.sh is the single source of truth for the architecture id and is
# executed directly here, so the tests always exercise the shipped artifact.
#
# Covers:
#   * every supported value read from os-release (quoted, unquoted, single quoted)
#   * candidates that are empty, unreadable or hold an unsupported value
#   * the userspace-ABI fallback, including the 64-bit-kernel/32-bit-userland case
#   * the integration points, so a consumer cannot silently drift back to reading
#     /etc/os-release on its own
#
# Run: bash test-arch-detection.sh

set -u
cd "$(dirname "$0")"

RESOLVER="./resolve-arch.sh"

if [ ! -f "$RESOLVER" ]; then
  echo "FAIL: $RESOLVER not found"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- shims so the userspace-ABI branch is drivable -------------------------
mkdir -p "$TMP/shim"
cat > "$TMP/shim/uname" <<'EOF'
#!/bin/sh
echo "${SHIM_MACHINE:-aarch64}"
EOF
cat > "$TMP/shim/getconf" <<'EOF'
#!/bin/sh
echo "${SHIM_BITS:-32}"
EOF
chmod +x "$TMP/shim/uname" "$TMP/shim/getconf"

# --- fixtures --------------------------------------------------------------
printf 'PRETTY_NAME="Volumio"\nVOLUMIO_ARCH="arm"\nVOLUMIO_VARIANT="volumio"\n' > "$TMP/osr-arm"
printf 'VOLUMIO_ARCH="armv7"\n'                                                 > "$TMP/osr-armv7"
printf 'VOLUMIO_ARCH="armv8"\n'                                                 > "$TMP/osr-armv8"
printf 'VOLUMIO_ARCH="x64"\n'                                                   > "$TMP/osr-x64"
printf 'VOLUMIO_ARCH=armv8\n'                                                   > "$TMP/osr-unquoted"
printf "VOLUMIO_ARCH='x64'\n"                                                   > "$TMP/osr-single"
printf 'VOLUMIO_ARCH="arm"\r\n'                                                 > "$TMP/osr-crlf"
printf 'VOLUMIO_ARCH=""\nVOLUMIO_VARIANT="volumio"\n'                           > "$TMP/osr-empty"
printf 'VOLUMIO_ARCH="garbage"\n'                                               > "$TMP/osr-bogus"
printf 'VOLUMIO_ARCH_SUFFIX="armv8"\n'                                          > "$TMP/osr-decoy"
# what a base-files upgrade leaves behind on Volumio
printf 'PRETTY_NAME="Raspbian GNU/Linux 12 (bookworm)"\nVERSION_ID="12"\n'       > "$TMP/osr-stock"

# Device under test, for regression reference:
#   uname -m = aarch64, getconf LONG_BIT = 32, VOLUMIO_ARCH = "arm"

PASS=0
FAIL=0

# run_case <desc> <expect> <machine> <bits> <candidate files...>
run_case() {
  local desc="$1" expect="$2" machine="$3" bits="$4"; shift 4
  local got
  got=$(SHIM_MACHINE="$machine" SHIM_BITS="$bits" PATH="$TMP/shim:$PATH" \
        bash "$RESOLVER" "$@")
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS + 1))
    printf '  ok   %-50s %-8s %-3s -> %s\n' "$desc" "$machine" "$bits" "${got:-<empty>}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %-50s %-8s %-3s -> got=%s want=%s\n' \
      "$desc" "$machine" "$bits" "${got:-<empty>}" "${expect:-<empty>}"
  fi
}

echo "Testing $RESOLVER"

# ---- values read from os-release -----------------------------------------
run_case "arm"                                  arm    aarch64 32 "$TMP/osr-arm"
run_case "armv7"                                armv7  aarch64 32 "$TMP/osr-armv7"
run_case "armv8"                                armv8  aarch64 64 "$TMP/osr-armv8"
run_case "x64"                                  x64    x86_64  64 "$TMP/osr-x64"
run_case "unquoted value"                       armv8  aarch64 64 "$TMP/osr-unquoted"
run_case "single quoted value"                  x64    aarch64 32 "$TMP/osr-single"
run_case "CRLF line ending"                     arm    aarch64 32 "$TMP/osr-crlf"
run_case "VOLUMIO_ARCH_SUFFIX is not a match"   armv8  aarch64 64 "$TMP/osr-decoy" "$TMP/osr-armv8"
run_case "os-release wins over the ABI probe"   arm    x86_64  64 "$TMP/osr-arm"

# ---- candidate handling ---------------------------------------------------
run_case "empty value falls through"            arm    aarch64 32 "$TMP/osr-empty" "$TMP/osr-arm"
run_case "unreadable candidate is skipped"      arm    aarch64 32 "$TMP/nope" "$TMP/osr-arm"
run_case "unsupported value falls through"      arm    aarch64 32 "$TMP/osr-bogus" "$TMP/osr-arm"

# ---- userspace-ABI fallback ----------------------------------------------
run_case "64-bit kernel + 32-bit userland"      arm    aarch64 32 "$TMP/osr-stock"
run_case "64-bit kernel + 64-bit userland"      armv8  aarch64 64 "$TMP/osr-stock"
run_case "armv7l userland"                      arm    armv7l  32 "$TMP/osr-stock"
run_case "armv6l userland"                      arm    armv6l  32 "$TMP/osr-stock"
run_case "x86_64 userland"                      x64    x86_64  64 "$TMP/osr-stock"
run_case "unknown platform stays empty"         ""     riscv64 64 "$TMP/osr-stock"

# ---- integration / anti-drift --------------------------------------------
echo
echo "Integration"

check() { # <desc> <condition-result>
  if [ "$2" = "0" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"
  fi
}

# the JS consumer takes the first token of stdout, so single-line output is the contract
lines=$(bash "$RESOLVER" "$TMP/osr-arm" | wc -l)
[ "$lines" = "1" ]
check "resolver prints exactly one line" $?

# both sides of the boundary validate the id against the same set
grep -q "ARCH_IDS.indexOf(detected)" index.js
check "index.js validates the id against ARCH_IDS" $?

grep -q "'arm', 'armv7', 'armv8', 'x64'" index.js
check "index.js declares the supported id set" $?

grep -q 'resolve-arch.sh' run_peppymeter.sh
check "run_peppymeter.sh uses resolve-arch.sh" $?

grep -q 'resolve-arch.sh' install.sh
check "install.sh uses resolve-arch.sh" $?

grep -q 'resolveVolumioArch' index.js
check "index.js exposes resolveVolumioArch()" $?

# the regression this patch exists to prevent: a consumer resolving the arch on its own
! grep -q 'VOLUMIO_ARCH' index.js
check "index.js has no direct VOLUMIO_ARCH read left" $?

! grep -q 'tr -d .VOLUMIO_ARCH' run_peppymeter.sh install.sh
check "shell consumers dropped the old os-release extraction" $?

! grep -q 'resolve_volumio_arch' run_peppymeter.sh install.sh
check "no leftover duplicated resolver function" $?

grep -q 'var _volumioArch = null;' index.js
check "index.js caches the resolved value" $?

# the default probe list must still cover the Volumio copies
grep -q '/etc/os-release /static/usr/lib/os-release /usr/lib/os-release' "$RESOLVER"
check "default candidate list intact" $?

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
