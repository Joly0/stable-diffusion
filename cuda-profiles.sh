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
#
# cu132 IS DEFINED BELOW BUT DELIBERATELY NOT LISTED HERE.
#
# PyTorch publishes no torchaudio for cu132 -- the index carries only a generic
# 2.2.0 from 2024, no +cu132 build at any version. ComfyUI imports torchaudio
# unconditionally (comfy/sd.py -> ldm/lightricks/vae/audio_vae.py), and
# torchaudio's _check_cuda_version() refuses to load against a torch built for a
# different CUDA minor:
#     RuntimeError: PyTorch has CUDA version 13.2 whereas TorchAudio has 13.0
# so ComfyUI cannot start at all on cu132.
#
# Nothing is lost by excluding it: cu130 and cu132 have IDENTICAL SASS arch
# lists ({75,80,86,90,100,120}), so cu132 covers no GPU that cu130 does not.
# It only tracks a newer CUDA minor. Re-add it to this list the day a
# torchaudio+cu132 wheel exists.
SD_CUDA_PROFILES="cu130 cu126"

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
    # WHY 2.12.1 AND NOT THE LATEST (2.13.0)
    # kaolin does not compile against torch 2.13. It is not merely the version
    # assertion in its setup.py -- with IGNORE_TORCH_VER=1 set, the build fails
    # for real in kaolin/csrc/ops/conversions/mise/mise.cpp:
    #     error: no matching function for call to 'zeros(...)'
    # because the at::zeros overload it uses changed signature in 2.13. Upstream
    # kaolin declares a ceiling of 2.12.1 and that ceiling is honest. There is no
    # open kaolin issue for 2.13, so no fix is imminent.
    #
    # The cost of holding here is small: 2.12.1 shipped 2026-06-18 and 2.13.0 on
    # 2026-07-08, about three weeks apart, and 2.12.1 is published for all three
    # profiles so nothing about GPU coverage changes.
    #
    # To move to 2.13.0, drop kaolin from SD_BUILD_PACKAGES and set:
    #   SD_TORCH_VERSION_OVERRIDE=2.13.0 SD_TORCHVISION_VERSION_OVERRIDE=0.28.0
    #
    # torchaudio MUST be pinned to the profile index too, and it used to not be.
    # Leaving it to a UI's own `pip install -r requirements.txt` resolves it from
    # PyPI, whose only build targets CUDA 13.0, and torchaudio then refuses to
    # load against a torch built for any other CUDA minor:
    #     RuntimeError: Detected that PyTorch and TorchAudio were compiled with
    #     different CUDA versions. PyTorch has CUDA version 13.2 whereas
    #     TorchAudio has CUDA version 13.0.
    #
    # Its version does NOT track torch: torchaudio is frozen at 2.11.0 while
    # torch is at 2.12.1. That pairing is fine -- verified by installing both
    # from the cu130 index and importing torchaudio successfully -- because the
    # check is on the CUDA version, not the torch version. What matters is only
    # that both come from the SAME index.
    local torch_version="${SD_TORCH_VERSION_OVERRIDE:-2.12.1}"
    local torchvision_version="${SD_TORCHVISION_VERSION_OVERRIDE:-0.27.1}"
    local torchaudio_version="${SD_TORCHAUDIO_VERSION_OVERRIDE:-2.11.0}"

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
            export TORCH_CUDA_ARCH_LIST="7.5;8.0;8.6;8.9;9.0;10.0;12.0"
            export SD_SAGE_ARCH_LIST="8.0;8.6;8.9;10.0;12.0"
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
            export TORCH_CUDA_ARCH_LIST="7.5;8.0;8.6;8.9;9.0;10.0;12.0"
            # 10.0 (datacenter Blackwell: B100/B200/GB200) must be listed
            # explicitly. It is a different compute-capability MAJOR from both
            # 9.0 and 12.0, so no other cubin here can serve it -- binary
            # compatibility only covers X.y -> X.z for z >= y. torch's own cu130
            # build ships sm_100, so omitting it left SageAttention as the one
            # component those cards could not use.
            #
            # 12.1 is deliberately absent: the 12.0 cubin covers it under that
            # same rule, which is why pytorch's own arch table stops at 120.
            # 9.0 (Hopper) is deliberately EXCLUDED. SageAttention gives every
            # extension the same NVCC_FLAGS -- there is no per-extension arch
            # scoping -- so asking for 9.0 alongside anything lower compiles the
            # Hopper-only source csrc/qattn/qk_int_sv_f8_cuda_sm90.cu for
            # compute_80/86/89 as well, and ptxas rejects it:
            #     error: Feature 'mbarrier.arrive.expect_tx' requires .target sm_90
            #     error: Feature 'cp.async.bulk.tensor' requires .target sm_90
            # It is genuinely either/or: a list containing 9.0 can contain
            # nothing else. Excluding it costs H100/H800 users SageAttention
            # (they fall back to PyTorch SDPA) and keeps it working for every
            # consumer GPU. _qattn_sm89 is unaffected -- its FP8 paths are
            # guarded by __CUDA_ARCH__ and compile away on lower targets.
            export SD_SAGE_ARCH_LIST="8.0;8.6;8.9;10.0;12.0"
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
            export TORCH_CUDA_ARCH_LIST="6.1;7.0;7.5;8.0;8.6;8.9;9.0"
            # 9.0 excluded for the same reason as cu130 above.
            export SD_SAGE_ARCH_LIST="8.0;8.6;8.9"
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
    export SD_TORCHAUDIO_VERSION="$torchaudio_version"

    # Build-time spec: the wheel builders link against torch and torchvision
    # only, so torchaudio is not downloaded there.
    export SD_TORCH_SPEC="torch==${torch_version} torchvision==${torchvision_version}"

    # Runtime spec: adds torchaudio, which several UIs import. Anything a UI
    # might pull from PyPI must be pinned to the profile index instead.
    export SD_TORCH_RUNTIME_SPEC="${SD_TORCH_SPEC} torchaudio==${torchaudio_version}"
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
# 2.12.1 the resolver therefore finds nothing and flash-attn is simply absent.
# That is the intended trade: newest torch for ComfyUI beats flash-attn, which
# needs sm_80+ anyway (Turing needs a fork, Pascal cannot run it at all) and is
# superseded by SageAttention 2++ for diffusion workloads.
#
# To actually get flash-attn, pin a profile back to a supported torch minor:
#   SD_TORCH_VERSION_OVERRIDE=2.10.0 SD_TORCHVISION_VERSION_OVERRIDE=0.25.0  (cu130)
#   SD_TORCH_VERSION_OVERRIDE=2.9.1  SD_TORCHVISION_VERSION_OVERRIDE=0.24.1  (cu126)
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# SageAttention build variants
#
# Some CUDA architectures cannot share a wheel with others. SageAttention hands
# every CUDAExtension one shared NVCC_FLAGS list, with no per-extension arch
# scoping, so a source file that uses arch-gated PTX gets compiled for every
# requested target and ptxas rejects it. sm_90 is the current example: its
# Hopper-only TMA/mbarrier instructions cannot be compiled for compute_80/86/89,
# so asking for 9.0 alongside anything lower fails the whole build.
#
# Upstream does not really support multi-arch redistributable builds at all --
# its documented install path compiles on the target machine, where only the
# local GPU's capability is emitted (see the open "support TORCH_CUDA_ARCH_LIST"
# issues). We build fat wheels, so we hit this and they do not.
#
# The fix is to build such architectures as SEPARATE wheels and choose between
# them at container start, which the runtime already has the information to do.
#
# ADDING A FUTURE ARCHITECTURE that turns out to be similarly exclusive is a
# config change only: add its name here and a case below. Nothing in the
# Dockerfile, the CI matrix or the runtime selector needs to know about it --
# the selector derives which variant serves a GPU from the arch lists
# themselves, using the CUDA binary-compatibility rule.
SD_SAGE_VARIANTS="sm90"

# sage_variant_arches <variant> -> the arch list that variant is compiled for.
# Must be semicolon separated, for the reason documented on SD_SAGE_ARCH_LIST.
sage_variant_arches() {
    case "$1" in
        # Hopper. A 9.0 build is complete rather than partial: _qattn_sm80 and
        # _qattn_sm89 are also gated on HAS_SM90, so every module is built, just
        # with Hopper gencode.
        sm90) echo "9.0" ;;
        *) return 1 ;;
    esac
}

# sage_variant_serves <arch-list> <compute-cap>
#
# True when a wheel built for <arch-list> contains a cubin that can execute on a
# GPU of <compute-cap>, per CUDA binary compatibility: a cubin for X.y runs on
# X.z when z >= y, and never across a different major.
#
# This is what makes the mechanism future proof -- variants are matched by what
# they can actually run, not by a hardcoded name-to-GPU table.
sage_variant_serves() {
    local arch_list="$1" cc="$2"
    local cc_major="${cc%%.*}" cc_minor="${cc#*.}"
    [ "$cc_minor" = "$cc" ] && cc_minor=0
    local entry a_major a_minor
    for entry in $(printf '%s' "$arch_list" | tr ',;' '  '); do
        entry="${entry%+PTX}"; entry="${entry%+ptx}"; entry="${entry%a}"
        [ -z "$entry" ] && continue
        a_major="${entry%%.*}"; a_minor="${entry#*.}"
        [ "$a_minor" = "$entry" ] && a_minor=0
        [ "$a_major" = "$cc_major" ] || continue
        [ "$a_minor" -le "$cc_minor" ] && return 0
    done
    return 1
}

SD_FLASH_ATTN_VERSION="2.8.3"
SD_FLASH_ATTN_REPO="Dao-AILab/flash-attention"
