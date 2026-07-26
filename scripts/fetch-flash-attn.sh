#!/usr/bin/env bash
# =============================================================================
# Resolve and download a PREBUILT flash-attention wheel.
#
# This replaces compiling flash-attention from source, which was by far the most
# expensive step in the buildbase: ~96 CUDA files times several arch targets,
# hours of wall time and the usual cause of OOM kills on a self-hosted runner.
# Dao-AILab publishes ~50 release assets per version; if one matches our
# coordinate there is no reason to build anything.
#
# Asset naming:
#   flash_attn-<ver>+cu<major>torch<M.m>cxx11abi<TRUE|FALSE>-<cp>-<cp>-linux_x86_64.whl
#
# The (cuda major, torch minor, cxx11 abi, python) tuple is a hard ABI
# coordinate -- the wheel links against libtorch, whose C++ ABI changes every
# torch minor. A near miss is not usable, so this script never "falls back" to
# a different torch minor. It either finds an exact match or exits 0 having
# downloaded nothing.
#
# Exit code is 0 even when nothing matches: flash-attn is optional. It needs
# sm_80+ (Ampere/Ada/Hopper -- Turing needs a separate fork, Pascal cannot run
# it at all) and SageAttention 2++ outperforms it for diffusion anyway.
#
# Usage: fetch-flash-attn.sh <output-dir>
#
# Env:
#   SD_FLASH_ATTN_VERSION   release tag body, e.g. 2.8.3       (required)
#   SD_FLASH_ATTN_REPO      owner/name, default Dao-AILab/flash-attention
#   SD_CUDA_MAJOR           12 or 13                           (required)
#   SD_TORCH_VERSION        e.g. 2.13.0                        (required)
#   PYTHON_TAG              e.g. cp312                         (required)
#   GITHUB_TOKEN            optional, raises the API rate limit
# =============================================================================
set -euo pipefail

out_dir="${1:?usage: fetch-flash-attn.sh <output-dir>}"
repo="${SD_FLASH_ATTN_REPO:-Dao-AILab/flash-attention}"
version="${SD_FLASH_ATTN_VERSION:?SD_FLASH_ATTN_VERSION is required}"
cuda_major="${SD_CUDA_MAJOR:?SD_CUDA_MAJOR is required}"
torch_version="${SD_TORCH_VERSION:?SD_TORCH_VERSION is required}"
python_tag="${PYTHON_TAG:?PYTHON_TAG is required}"

# torch 2.13.0 -> 2.13, which is what appears in the asset name.
torch_minor="${torch_version%.*}"

mkdir -p "$out_dir"

echo "flash-attn: looking for v${version} matching cu${cuda_major} / torch ${torch_minor} / ${python_tag}"

auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

api="https://api.github.com/repos/${repo}/releases/tags/v${version}"
release_json=$(curl -fsSL --retry 3 --retry-delay 2 --max-time 60 "${auth[@]}" "$api") || {
    echo "flash-attn: could not read release v${version} from ${repo}; skipping."
    exit 0
}

# Prefer cxx11abiTRUE. Modern torch wheels are built with _GLIBCXX_USE_CXX11_ABI=1,
# and every recent flash-attn asset is TRUE-only anyway; FALSE is a legacy path.
url=$(printf '%s' "$release_json" | python3 -c '
import json, re, sys

release = json.load(sys.stdin)
cuda_major, torch_minor, python_tag = sys.argv[1:4]

pattern = re.compile(
    r"^flash_attn-.*\+cu%s"
    r"torch%s"
    r"cxx11abi(TRUE|FALSE)-%s-%s-linux_x86_64\.whl$"
    % (re.escape(cuda_major), re.escape(torch_minor),
       re.escape(python_tag), re.escape(python_tag))
)

matches = []
for asset in release.get("assets", []):
    m = pattern.match(asset["name"])
    if m:
        # sort key: cxx11abiTRUE first
        matches.append((0 if m.group(1) == "TRUE" else 1, asset["name"],
                        asset["browser_download_url"]))

if matches:
    matches.sort()
    # name first, then url: the download URL percent-encodes the "+" in the
    # local version ("%2B"), and a wheel saved under that name is not a valid
    # wheel filename -- pip refuses it. Always save under the asset name.
    print(matches[0][1])
    print(matches[0][2])
' "$cuda_major" "$torch_minor" "$python_tag")

name=$(printf '%s' "$url" | sed -n 1p)
url=$(printf '%s' "$url" | sed -n 2p)

if [ -z "$url" ]; then
    echo "flash-attn: no prebuilt wheel published for cu${cuda_major} + torch ${torch_minor} + ${python_tag}."
    echo "flash-attn: skipping (optional). To get one, pin this profile to a torch"
    echo "flash-attn: minor that has a published asset -- see cuda-profiles.sh."
    exit 0
fi

echo "flash-attn: downloading ${name}"
curl -fsSL --retry 3 --retry-delay 2 --max-time 600 -o "${out_dir}/${name}" "$url"
echo "flash-attn: done."
