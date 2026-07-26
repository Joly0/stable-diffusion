#!/usr/bin/env bash
# =============================================================================
# Assert that a built wheel actually contains cubins for the architectures we
# asked for.
#
# WHY THIS EXISTS
#
# SageAttention parses TORCH_CUDA_ARCH_LIST with its own splitter:
#     for item in arch_list_env.replace(",", ";").split(";")
# which handles ';' and ',' but NOT whitespace. A space-separated list --
# the form torch itself accepts, and the form this repo used -- collapses into a
# single bogus capability string. That string still matches startswith("8.0"),
# so the build succeeds, emits sm_80 kernels only, and says nothing. The failure
# surfaces much later on a user's machine as
#     Error running sage attention: SM89 kernel is not available.
#
# A build that silently produces the wrong kernels is worse than one that fails,
# so the artifact is checked here rather than trusted.
#
# Usage: verify-wheel-arches.sh <wheel> <arch-list>
#   <arch-list> may be ';', ',' or space separated, e.g. "8.0;8.9;12.0"
#   Entries ending in +PTX are checked as PTX rather than SASS.
# =============================================================================
set -euo pipefail

wheel="${1:?usage: verify-wheel-arches.sh <wheel> <arch-list>}"
arch_list="${2:?usage: verify-wheel-arches.sh <wheel> <arch-list>}"

if ! command -v cuobjdump >/dev/null 2>&1; then
    echo "verify-wheel-arches: cuobjdump not found, skipping verification" >&2
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 -m zipfile -e "$wheel" "$tmp"

# Collect every SASS arch present across all extension modules in the wheel.
found=""
while IFS= read -r so; do
    found="${found} $(cuobjdump --list-elf "$so" 2>/dev/null | grep -oE 'sm_[0-9]+' | sort -u | tr '\n' ' ')"
done < <(find "$tmp" -name '*.so' -o -name '*.pyd')
found=$(printf '%s' "$found" | tr ' ' '\n' | grep -E '^sm_[0-9]+$' | sort -u | tr '\n' ' ')

echo "verify-wheel-arches: $(basename "$wheel")"
echo "  requested : ${arch_list}"
echo "  found     : ${found:-<none>}"

missing=""
for entry in $(printf '%s' "$arch_list" | tr ',;' '  '); do
    case "$entry" in
        ''|*+PTX|*+ptx) continue ;;   # PTX-only targets emit no SASS
    esac
    # 8.9 -> sm_89
    want="sm_$(printf '%s' "$entry" | tr -d '.')"
    case " ${found} " in
        *" ${want} "*) ;;
        *) missing="${missing} ${want}" ;;
    esac
done

if [ -n "$missing" ]; then
    echo "  FATAL: wheel is missing kernels for:${missing}" >&2
    echo "  The arch list was probably not parsed the way you expect." >&2
    echo "  SageAttention splits only on ';' and ',' -- never on spaces." >&2
    exit 1
fi

echo "  OK: every requested architecture is present"
