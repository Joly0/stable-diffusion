#!/bin/bash
# Exercises detect_cuda_profile() against synthetic nvidia-smi output.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

FAKE_BIN=$(mktemp -d)
export PATH="$FAKE_BIN:$PATH"

make_smi() {
    cat > "$FAKE_BIN/nvidia-smi" <<EOF
#!/bin/bash
case "\$*" in
  *compute_cap*)     printf '%s\n' $1 ;;
  *driver_version*)  printf '%s\n' "$2" ;;
esac
EOF
    chmod +x "$FAKE_BIN/nvidia-smi"
}

run_case() {
    local desc="$1" caps="$2" drv="$3" expect="$4"
    make_smi "$caps" "$drv"
    local out
    out=$(env -u SD_CUDA_PROFILE bash -c '
        . ./cuda-profiles.sh >/dev/null 2>&1
        . ./functions.sh >/dev/null 2>&1
        detect_cuda_profile >/dev/null 2>&1
        echo "$SD_CUDA_PROFILE"
    ')
    if [ "$out" = "$expect" ]; then
        printf 'PASS  %-46s -> %s\n' "$desc" "$out"
    else
        printf 'FAIL  %-46s -> %s (expected %s)\n' "$desc" "$out" "$expect"
        FAILED=1
    fi
}

FAILED=0
echo "--- single GPU ---"
run_case "GTX 1080 Ti (6.1), driver 550"      "'6.1'"        "550.144.03" cu126
run_case "GTX 1080 Ti (6.1), driver 610"      "'6.1'"        "610.43.02"  cu126
run_case "Titan V (7.0), driver 580"          "'7.0'"        "580.95.05"  cu126
run_case "RTX 2080 (7.5), driver 550"         "'7.5'"        "550.144.03" cu126
run_case "RTX 2080 (7.5), driver 580"         "'7.5'"        "580.95.05"  cu130
run_case "RTX 3090 (8.6), driver 585"         "'8.6'"        "585.10.00"  cu130
run_case "RTX 4090 (8.9), driver 600"         "'8.9'"        "600.00.00"  cu130
run_case "H100 (9.0), driver 595"             "'9.0'"        "595.58.03"  cu130
run_case "RTX 5090 (12.0), driver 610"        "'12.0'"       "610.43.02"  cu130
run_case "RTX 5090 (12.0), driver 585"        "'12.0'"       "585.10.00"  cu130

echo "--- Blackwell on a too-old driver (must NOT land on cu126) ---"
run_case "RTX 5090 (12.0), driver 570"        "'12.0'"       "570.86.15"  cu130

echo "--- multi-GPU: weakest card decides ---"
run_case "5090 + 1080 Ti, driver 610"         "'12.0' '6.1'" "610.43.02"  cu126
run_case "4090 + 3090, driver 600"            "'8.9' '8.6'"  "600.00.00"  cu130
run_case "4090 + 2080, driver 585"            "'8.9' '7.5'"  "585.10.00"  cu130

echo "--- degraded / edge cases ---"
run_case "compute_cap without minor"          "'9'"          "600.00.00"  cu130
run_case "garbage driver string"              "'8.6'"        "unknown"    cu126

echo "--- no GPU at all ---"
# NOTE: must shadow nvidia-smi with a failing stub, not delete it -- the build
# host has a real one on PATH and would otherwise answer for itself.
printf '#!/bin/bash\nexit 1\n' > "$FAKE_BIN/nvidia-smi"; chmod +x "$FAKE_BIN/nvidia-smi"
out=$(env -u SD_CUDA_PROFILE bash -c '
    . ./cuda-profiles.sh; . ./functions.sh >/dev/null 2>&1
    detect_cuda_profile >/dev/null 2>&1; echo "$SD_CUDA_PROFILE"')
[ "$out" = "cu126" ] && printf 'PASS  %-46s -> %s\n' "no nvidia-smi present" "$out" \
                     || { printf 'FAIL  no nvidia-smi -> %s\n' "$out"; FAILED=1; }

echo "--- explicit override ---"
make_smi "'8.9'" "600.00.00"
out=$(SD_CUDA_PROFILE=cu126 bash -c '
    . ./cuda-profiles.sh; . ./functions.sh >/dev/null 2>&1
    detect_cuda_profile >/dev/null 2>&1; echo "$SD_CUDA_PROFILE|$TORCH_INDEX_URL"')
[ "$out" = "cu126|https://download.pytorch.org/whl/cu126" ] \
    && printf 'PASS  %-46s -> %s\n' "SD_CUDA_PROFILE=cu126 honoured" "$out" \
    || { printf 'FAIL  override -> %s\n' "$out"; FAILED=1; }

# bogus override must be discarded and autodetect must take over (8.9 @ 600 -> cu130)
out=$(SD_CUDA_PROFILE=nonsense bash -c '
    . ./cuda-profiles.sh; . ./functions.sh >/dev/null 2>&1
    detect_cuda_profile >/dev/null 2>&1; echo "$SD_CUDA_PROFILE"')
[ "$out" = "cu130" ] && printf 'PASS  %-46s -> %s\n' "bogus override ignored" "$out" \
                     || { printf 'FAIL  bogus override -> %s\n' "$out"; FAILED=1; }


# --- SageAttention arch-variant selection ---------------------------------
# Some arches cannot share a wheel (sm_90 today) so they are built separately
# and chosen at runtime. These check the CHOICE, which is derived from arch
# lists via CUDA binary compatibility rather than a hardcoded GPU table.
echo "--- sage variant selection ---"

WHEELS=$(mktemp -d)
mkdir -p "$WHEELS/sm90"
touch "$WHEELS/sageattention-2.2.0-cp312.whl" "$WHEELS/diso-0.1.4-cp312.whl" \
      "$WHEELS/sm90/sageattention-2.2.0-cp312.whl"

variant_case() {
    local desc="$1" profile="$2" cc="$3" expect="$4"
    local out
    out=$(env -u SD_CUDA_PROFILE bash -c '
        . ./cuda-profiles.sh >/dev/null 2>&1
        . ./functions.sh >/dev/null 2>&1
        cuda_profile_config '"$profile"' >/dev/null
        SD_WHEELS_DIR="'"$WHEELS"'"
        SD_GPU_MIN_CC="'"$cc"'"
        d=$(_sage_variant_dir) && basename "$d" || echo default
    ')
    if [ "$out" = "$expect" ]; then
        printf 'PASS  %-46s -> %s\n' "$desc" "$out"
    else
        printf 'FAIL  %-46s -> %s (expected %s)\n' "$desc" "$out" "$expect"; FAILED=1
    fi
}

variant_case "H100 (9.0) on cu130 -> isolated sm90 build"  cu130 "9.0"  sm90
variant_case "H100 (9.0) on cu126 -> isolated sm90 build"  cu126 "9.0"  sm90
variant_case "RTX 4090 (8.9) -> default build"             cu130 "8.9"  default
variant_case "RTX 3090 (8.6) -> default build"             cu130 "8.6"  default
variant_case "A100 (8.0) -> default build"                 cu130 "8.0"  default
variant_case "RTX 5090 (12.0) -> default build"            cu130 "12.0" default
variant_case "B200 (10.0) -> default build"                cu130 "10.0" default
variant_case "sm_12.1 served by the 12.0 cubin"            cu130 "12.1" default
variant_case "RTX 2080 (7.5), no sage kernels at all"      cu130 "7.5"  default

# Future-proofing: a NEW exclusive architecture must route correctly with no
# code change -- only a cuda-profiles.sh entry. Simulate one.
out=$(env -u SD_CUDA_PROFILE bash -c '
    . ./cuda-profiles.sh >/dev/null 2>&1
    . ./functions.sh >/dev/null 2>&1
    cuda_profile_config cu130 >/dev/null
    SD_SAGE_VARIANTS="sm90 sm150"
    sage_variant_arches() { case "$1" in sm90) echo 9.0;; sm150) echo 15.0;; *) return 1;; esac; }
    SD_WHEELS_DIR="'"$WHEELS"'"; SD_GPU_MIN_CC="15.0"
    d=$(_sage_variant_dir) && basename "$d" || echo default
')
mkdir -p "$WHEELS/sm150"; touch "$WHEELS/sm150/sageattention-2.2.0-cp312.whl"
out=$(env -u SD_CUDA_PROFILE bash -c '
    . ./cuda-profiles.sh >/dev/null 2>&1
    . ./functions.sh >/dev/null 2>&1
    cuda_profile_config cu130 >/dev/null
    SD_SAGE_VARIANTS="sm90 sm150"
    sage_variant_arches() { case "$1" in sm90) echo 9.0;; sm150) echo 15.0;; *) return 1;; esac; }
    SD_WHEELS_DIR="'"$WHEELS"'"; SD_GPU_MIN_CC="15.0"
    d=$(_sage_variant_dir) && basename "$d" || echo default
')
[ "$out" = "sm150" ] && printf 'PASS  %-46s -> %s\n' "hypothetical future arch routes by config" "$out" \
                     || { printf 'FAIL  future arch -> %s (expected sm150)\n' "$out"; FAILED=1; }

rm -rf "$WHEELS"

rm -rf "$FAKE_BIN"
echo
[ "$FAILED" = "1" ] && { echo "SOME TESTS FAILED"; exit 1; }
echo "ALL TESTS PASSED"
