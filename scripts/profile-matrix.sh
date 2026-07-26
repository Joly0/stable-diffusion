#!/usr/bin/env bash
# =============================================================================
# Emit the CI build matrix as JSON, derived from cuda-profiles.sh.
#
# CI must never carry its own copy of a torch version or an index URL. If the
# workflow hardcoded them they would drift from what functions.sh installs at
# runtime, and the wheels would be built against a different libtorch than the
# one they get imported into -- which surfaces as an ImportError on a user's
# machine, long after CI went green.
#
# Usage:
#   profile-matrix.sh profiles          # one entry per CUDA profile
#   profile-matrix.sh builds            # one entry per (profile, package) pair
#
# Env:
#   SD_PROFILES        space-separated subset to emit (default: all)
#   SD_BUILD_PACKAGES  space-separated compiled packages (default: the four below)
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cuda-profiles.sh
. "${here}/cuda-profiles.sh"

mode="${1:?usage: profile-matrix.sh profiles|builds}"

# flash-attn is intentionally NOT here: it is downloaded, not compiled, so it
# does not need a CUDA build image at all and gets its own cheap CI job.
packages="${SD_BUILD_PACKAGES:-sageattention diso nvdiffrast kaolin}"
profiles="${SD_PROFILES:-${SD_CUDA_PROFILES}}"

emit_profile_json() {
    local p="$1"
    cuda_profile_config "$p" >/dev/null
    python3 -c '
import json, sys
print(json.dumps({
    "profile":      sys.argv[1],
    "cuda_major":   sys.argv[2],
    "cuda_image":   sys.argv[3],
    "torch_index":  sys.argv[4],
    "torch_version": sys.argv[5],
    "torch_spec":   sys.argv[6],
    "arch_list":    sys.argv[7],
    "sage_arch_list": sys.argv[8],
    "package":      sys.argv[9],
}))' "$p" "$SD_CUDA_MAJOR" "$SD_CUDA_IMAGE" "$TORCH_INDEX_URL" \
     "$SD_TORCH_VERSION" "$SD_TORCH_SPEC" "$TORCH_CUDA_ARCH_LIST" \
     "$SD_SAGE_ARCH_LIST" "${2:-}"
}

{
    for p in $profiles; do
        case "$mode" in
            profiles) emit_profile_json "$p" ;;
            builds)   for pkg in $packages; do emit_profile_json "$p" "$pkg"; done ;;
            *) echo "unknown mode '$mode'" >&2; exit 1 ;;
        esac
    done
} | python3 -c 'import json,sys; print(json.dumps({"include":[json.loads(l) for l in sys.stdin if l.strip()]}))'
