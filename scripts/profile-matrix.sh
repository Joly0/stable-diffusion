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

# emit_profile_json <profile> [package] [sage_arch_list] [wheel_subdir]
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
    "wheel_subdir": sys.argv[10],
    "job":          sys.argv[9] + ("-" + sys.argv[10] if sys.argv[10] else ""),
}))' "$p" "$SD_CUDA_MAJOR" "$SD_CUDA_IMAGE" "$TORCH_INDEX_URL" \
     "$SD_TORCH_VERSION" "$SD_TORCH_SPEC" "$TORCH_CUDA_ARCH_LIST" \
     "${3:-$SD_SAGE_ARCH_LIST}" "${2:-}" "${4:-}"
}

# Does this profile have GPUs that a given variant would serve? A profile whose
# compute-capability ceiling is below the variant should not waste a CI job on
# it. SD_MAX_COMPUTE_CAP of "none" means unbounded.
profile_wants_variant() {
    local arches="$1"
    [ "${SD_MAX_COMPUTE_CAP}" = "none" ] && return 0
    sage_variant_serves "$arches" "${SD_MAX_COMPUTE_CAP}"
}

{
    for p in $profiles; do
        case "$mode" in
            profiles) emit_profile_json "$p" ;;
            builds)
                for pkg in $packages; do
                    emit_profile_json "$p" "$pkg"
                    # SageAttention additionally gets one job per arch variant --
                    # architectures that cannot share a wheel with the default
                    # set. Purely config driven from cuda-profiles.sh.
                    if [ "$pkg" = "sageattention" ]; then
                        for variant in ${SD_SAGE_VARIANTS:-}; do
                            varches=$(sage_variant_arches "$variant") || continue
                            cuda_profile_config "$p" >/dev/null
                            profile_wants_variant "$varches" || continue
                            emit_profile_json "$p" "$pkg" "$varches" "$variant"
                        done
                    fi
                done
                ;;
            *) echo "unknown mode '$mode'" >&2; exit 1 ;;
        esac
    done
} | python3 -c 'import json,sys; print(json.dumps({"include":[json.loads(l) for l in sys.stdin if l.strip()]}))'
