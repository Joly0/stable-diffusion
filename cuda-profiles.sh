#!/bin/bash
# =============================================================================
# CUDA profile definitions -- SINGLE SOURCE OF TRUTH.
#
# Sourced by:
#   - functions.sh          (runtime, to pick a profile for the detected GPU)
#   - Dockerfile.buildbase  (build time, via --build-arg)
#   - .github/workflows/build-wheels.yml (CI matrix)
#
# Change a version here and every consumer follows. Do not hardcode a torch
# version or an index URL anywhere else.
#
# -----------------------------------------------------------------------------
# WHY THERE IS MORE THAN ONE PROFILE
#
# PyTorch ships different SASS architectures per CUDA build. From pytorch's own
# .ci/manywheel/build_env_setup.py (TORCH_CUDA_ARCH_LIST_TABLE), x86_64:
#
#   cu126 -> {50, 60, 70, 75, 80, 86, 90}          Maxwell .. Hopper
#   cu130 -> {75, 80, 86, 90, 100, 120}            Turing  .. Blackwell
#   cu132 -> {75, 80, 86, 90, 100, 120}            Turing  .. Blackwell
#
# cu126 is the ONLY remaining build with Maxwell/Pascal/Volta kernels -- pytorch
# dropped them from cu128/cu129 (pytorch#157517) and CUDA 13.0 removed the
# architectures outright. So a GTX 10xx owner needs cu126 and always will.
#
# Conversely cu126 has no sm_100/sm_120, so Blackwell (RTX 50xx) needs cu13x.
#
# The good news: the same torch release is published on all three indexes, so
# nobody is stuck on an old torch just because their GPU is old. Only the CUDA
# runtime differs.
#
# Note on binary compatibility: a cubin for sm_X.y also runs on sm_X.z where
# z >= y. That is why 8.9 (Ada / RTX 40xx) is covered by the 8.6 cubin, and 6.1
# (GTX 10xx) by the 6.0 cubin.
# =============================================================================

# Profiles in preference order, most modern first. The runtime picker walks this
# list and takes the first profile the host actually satisfies.
SD_CUDA_PROFILES="cu132 cu130 cu126"

# Default when no GPU is visible at all (CPU-only container, driver not passed
# through). cu126 has the widest hardware coverage, so it is the safe fallback.
SD_CUDA_PROFILE_FALLBACK="cu126"

# -----------------------------------------------------------------------------
# cuda_profile_config <profile>
#
# Exports the full configuration for one profile. Returns 1 on unknown profile.
#
# Exported:
#   SD_CUDA_PROFILE        profile name, e.g. cu130
#   SD_CUDA_MAJOR          12 or 13 -- used to resolve prebuilt wheel names
#   SD_CUDA_IMAGE          nvidia/cuda devel base image used to build the wheels
#   SD_CUDA_HOME           system CUDA toolkit to use for RUNTIME extension builds
#   TORCH_INDEX_URL        pytorch wheel index for this profile
#   SD_TORCH_VERSION       torch version pin
#   SD_TORCHVISION_VERSION torchvision version pin (tracks torch minor exactly)
#   SD_TORCH_SPEC          ready-to-use pip argument string
#   TORCH_CUDA_ARCH_LIST   arch list for generic CUDA extension builds
#   SD_SAGE_ARCH_LIST      narrower arch list for SageAttention (sm80+ only)
#   SD_MIN_COMPUTE_CAP     lowest compute capability this profile supports
#   SD_MAX_COMPUTE_CAP     highest compute capability this profile supports,
#                          or "none" when the profile has no upper bound
#   SD_MIN_DRIVER          lowest NVIDIA driver major version this profile needs
# -----------------------------------------------------------------------------
cuda_profile_config() {
    local profile="$1"

    # torch/torchvision are pinned as a pair: torchvision links against libtorch
    # and its ABI is not stable across torch minors, so they must move together.
    #
    # torchaudio is deliberately NOT pinned. Its last release is 2.11.0 while
    # torch is at 2.13, i.e. it is frozen, and it is not published for cu132 at
    # all. Scripts that need it install it unpinned and tolerate its absence.
    local torch_version="${SD_TORCH_VERSION_OVERRIDE:-2.13.0}"
    local torchvision_version="${SD_TORCHVISION_VERSION_OVERRIDE:-0.28.0}"

    case "$profile" in
        cu132)
            # Newest. Blackwell + whatever comes next. Needs a very recent driver.
            export SD_CUDA_MAJOR=13
            export SD_CUDA_IMAGE="nvidia/cuda:13.2.1-cudnn-devel-ubuntu24.04"
            # The runtime image ships one CUDA 13 toolkit (13.0). A minor
            # difference against a cu132 torch is a warning, not an error --
            # only the MAJOR has to match.
            export SD_CUDA_HOME="/usr/local/cuda-13.0"
            export TORCH_INDEX_URL="https://download.pytorch.org/whl/cu132"
            export TORCH_CUDA_ARCH_LIST="7.5 8.0 8.6 8.9 9.0 10.0 12.0"
            export SD_SAGE_ARCH_LIST="8.0 8.6 8.9 9.0 12.0"
            export SD_MIN_COMPUTE_CAP="7.5"
            export SD_MAX_COMPUTE_CAP="none"
            export SD_MIN_DRIVER="595"
            ;;
        cu130)
            # Default for anything Turing or newer on a current driver.
            export SD_CUDA_MAJOR=13
            export SD_CUDA_IMAGE="nvidia/cuda:13.0.3-cudnn-devel-ubuntu24.04"
            export SD_CUDA_HOME="/usr/local/cuda-13.0"
            export TORCH_INDEX_URL="https://download.pytorch.org/whl/cu130"
            export TORCH_CUDA_ARCH_LIST="7.5 8.0 8.6 8.9 9.0 10.0 12.0"
            export SD_SAGE_ARCH_LIST="8.0 8.6 8.9 9.0 12.0"
            export SD_MIN_COMPUTE_CAP="7.5"
            export SD_MAX_COMPUTE_CAP="none"
            export SD_MIN_DRIVER="580"
            ;;
        cu126)
            # Legacy hardware AND anyone on a pre-580 driver. Keeps Pascal alive.
            # No sm_100/sm_120 here, so Blackwell must never land on this profile.
            export SD_CUDA_MAJOR=12
            export SD_CUDA_IMAGE="nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04"
            # Runtime image carries a minimal CUDA 12.6 nvcc alongside the
            # CUDA 13 toolkit purely so this profile can compile extensions.
            export SD_CUDA_HOME="/usr/local/cuda-12.6"
            export TORCH_INDEX_URL="https://download.pytorch.org/whl/cu126"
            export TORCH_CUDA_ARCH_LIST="6.1 7.0 7.5 8.0 8.6 8.9 9.0"
            export SD_SAGE_ARCH_LIST="8.0 8.6 8.9 9.0"
            export SD_MIN_COMPUTE_CAP="5.0"
            # Hard upper bound: cu126 has no sm_100/sm_120 kernels, so a
            # Blackwell card must never be routed here even though it satisfies
            # the (much lower) driver requirement.
            export SD_MAX_COMPUTE_CAP="9.0"
            export SD_MIN_DRIVER="525"
            ;;
        *)
            echo "cuda-profiles: unknown profile '${profile}'" >&2
            return 1
            ;;
    esac

    export SD_CUDA_PROFILE="$profile"
    export SD_TORCH_VERSION="$torch_version"
    export SD_TORCHVISION_VERSION="$torchvision_version"
    export SD_TORCH_SPEC="torch==${torch_version} torchvision==${torchvision_version}"
}

# -----------------------------------------------------------------------------
# Prebuilt flash-attention wheels
#
# Dao-AILab publishes release assets named:
#   flash_attn-<ver>+cu<major>torch<torch_minor>cxx11abi<TRUE|FALSE>-<cp>-<cp>-linux_x86_64.whl
#
# The torch minor in that name is not cosmetic -- the wheel links against
# libtorch, whose C++ ABI changes every minor. A wheel built for torch 2.10 will
# not import under torch 2.13.
#
# As of the last check the newest published coordinates are cu13torch2.10 and
# cu12torch2.9, i.e. nothing for torch 2.11+. With the default pin of torch
# 2.13.0 the resolver therefore finds nothing and flash-attn is simply absent.
# That is the intended trade: newest torch for ComfyUI beats flash-attn, which
# needs sm_80+ anyway (Turing needs a fork, Pascal cannot run it at all) and is
# superseded by SageAttention 2++ for diffusion workloads.
#
# To actually get flash-attn, pin a profile back to a supported torch minor:
#   SD_TORCH_VERSION_OVERRIDE=2.10.0 SD_TORCHVISION_VERSION_OVERRIDE=0.25.0  (cu130)
#   SD_TORCH_VERSION_OVERRIDE=2.9.1  SD_TORCHVISION_VERSION_OVERRIDE=0.24.1  (cu126)
# -----------------------------------------------------------------------------
SD_FLASH_ATTN_VERSION="2.8.3"
SD_FLASH_ATTN_REPO="Dao-AILab/flash-attention"
