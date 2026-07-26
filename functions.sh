#!/bin/bash

# =============================================================================
# CUDA profile selection
#
# Every UI installs its own torch into its own conda env at first launch, which
# means "which CUDA build does this machine need" is a STARTUP decision, not a
# build decision. Nothing extra is downloaded because of this -- it is the same
# torch download, just from the index that matches the GPU and driver.
#
# Profile definitions (versions, arch lists, thresholds) live in
# cuda-profiles.sh. Nothing here hardcodes a version.
# =============================================================================

# shellcheck source=cuda-profiles.sh
if [ -f /cuda-profiles.sh ]; then
    . /cuda-profiles.sh
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/cuda-profiles.sh" ]; then
    . "$(dirname "${BASH_SOURCE[0]}")/cuda-profiles.sh"
fi

# Normalise "8.6" -> 86 so compute capabilities can be compared as integers.
# Handles a missing minor ("9" -> 90) and rejects anything non-numeric.
_cc_to_int() {
    local cc="$1" major minor
    case "$cc" in
        *[!0-9.]*|'') return 1 ;;
    esac
    major="${cc%%.*}"
    minor="${cc#*.}"
    [ "$minor" = "$cc" ] && minor=0
    minor="${minor%%.*}"
    [ -z "$major" ] && return 1
    [ -z "$minor" ] && minor=0
    echo $(( major * 10 + minor ))
}

# Populates SD_GPU_MIN_CC (weakest GPU in the box) and SD_DRIVER_MAJOR.
# Returns 1 when no usable GPU information is available.
#
# The WEAKEST GPU wins deliberately: in a mixed-GPU machine every UI runs one
# torch install, so it has to be the one that all cards can execute.
detect_gpu_capabilities() {
    command -v nvidia-smi >/dev/null 2>&1 || return 1

    local caps drivers cc cc_int lowest=""
    caps=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null) || return 1
    [ -z "$caps" ] && return 1

    while IFS= read -r cc; do
        cc="${cc// /}"
        [ -z "$cc" ] && continue
        cc_int=$(_cc_to_int "$cc") || continue
        if [ -z "$lowest" ] || [ "$cc_int" -lt "$lowest" ]; then
            lowest="$cc_int"
            SD_GPU_MIN_CC="$cc"
        fi
    done <<< "$caps"

    [ -z "$lowest" ] && return 1
    SD_GPU_MIN_CC_INT="$lowest"

    drivers=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1)
    SD_DRIVER_MAJOR="${drivers%%.*}"
    SD_DRIVER_MAJOR="${SD_DRIVER_MAJOR// /}"
    case "$SD_DRIVER_MAJOR" in
        ''|*[!0-9]*) SD_DRIVER_MAJOR=0 ;;
    esac

    export SD_GPU_MIN_CC SD_GPU_MIN_CC_INT SD_DRIVER_MAJOR
    return 0
}

# Selects a CUDA profile for this host and exports the full config for it.
#
# Honours an explicit SD_CUDA_PROFILE from the environment (docker -e
# SD_CUDA_PROFILE=cu126) so users can override a bad autodetect without
# rebuilding anything.
detect_cuda_profile() {
    echo "-------------------------------------"
    echo "Selecting CUDA profile"

    if ! command -v cuda_profile_config >/dev/null 2>&1; then
        echo "WARNING: cuda-profiles.sh not found, CUDA profile selection disabled."
        echo -e "-------------------------------------\n"
        return 1
    fi

    # 1. Explicit user override always wins.
    if [ -n "${SD_CUDA_PROFILE}" ]; then
        if cuda_profile_config "${SD_CUDA_PROFILE}"; then
            echo "Profile forced by SD_CUDA_PROFILE: ${SD_CUDA_PROFILE}"
            _report_cuda_profile
            return 0
        fi
        echo "WARNING: SD_CUDA_PROFILE='${SD_CUDA_PROFILE}' is not a known profile, ignoring."
        unset SD_CUDA_PROFILE
    fi

    # 2. No GPU visible -> widest-compatibility fallback.
    if ! detect_gpu_capabilities; then
        echo "No usable nvidia-smi output (no GPU passed through?)."
        echo "Falling back to ${SD_CUDA_PROFILE_FALLBACK}, which has the widest hardware coverage."
        cuda_profile_config "${SD_CUDA_PROFILE_FALLBACK}"
        _report_cuda_profile
        return 0
    fi

    echo "Detected: lowest compute capability ${SD_GPU_MIN_CC}, driver ${SD_DRIVER_MAJOR}.x"

    # 3. Walk profiles most-modern-first, take the first one this host satisfies.
    #
    # Track any profile the GPU itself qualifies for but the DRIVER rules out, so
    # the user is told an upgrade is available. Without this an Ada or Blackwell
    # card on an old driver silently lands on the legacy profile and looks fine.
    local profile min_int max_int
    local held_back="" held_back_driver=""
    for profile in ${SD_CUDA_PROFILES}; do
        cuda_profile_config "$profile" || continue

        min_int=$(_cc_to_int "${SD_MIN_COMPUTE_CAP}")
        [ "${SD_GPU_MIN_CC_INT}" -lt "$min_int" ] && continue

        if [ "${SD_MAX_COMPUTE_CAP}" != "none" ]; then
            max_int=$(_cc_to_int "${SD_MAX_COMPUTE_CAP}")
            [ "${SD_GPU_MIN_CC_INT}" -gt "$max_int" ] && continue
        fi

        if [ "${SD_DRIVER_MAJOR}" -lt "${SD_MIN_DRIVER}" ]; then
            # Remember only the first (most modern) one, and its requirement --
            # cuda_profile_config overwrites SD_MIN_DRIVER on the next iteration.
            if [ -z "$held_back" ]; then
                held_back="$profile"
                held_back_driver="${SD_MIN_DRIVER}"
            fi
            continue
        fi

        echo "Selected profile: ${profile}"
        if [ -n "$held_back" ]; then
            echo "NOTE: this GPU also supports the newer '${held_back}' profile, which needs"
            echo "NOTE: driver ${held_back_driver} or later -- this host has ${SD_DRIVER_MAJOR}.x."
            echo "NOTE: Updating the NVIDIA driver would switch to it automatically."
        fi
        _report_cuda_profile
        return 0
    done

    # 4. Nothing matched. Two very different reasons, so handle them separately.

    # 4a. The GPU is too NEW for the fallback: Blackwell on a pre-580 driver is
    #     too new for cu126 (no sm_120 kernels) and too old for cu130. cu126
    #     would install a torch that cannot run a single kernel on this card, so
    #     take the least-demanding CUDA 13 profile and say why.
    cuda_profile_config "${SD_CUDA_PROFILE_FALLBACK}"
    local fallback_max_int
    fallback_max_int=$(_cc_to_int "${SD_MAX_COMPUTE_CAP}")

    if [ "${SD_MAX_COMPUTE_CAP}" != "none" ] && [ "${SD_GPU_MIN_CC_INT}" -gt "$fallback_max_int" ]; then
        local candidate="" candidate_driver=""
        for profile in ${SD_CUDA_PROFILES}; do
            cuda_profile_config "$profile" || continue
            # SD_CUDA_PROFILES is ordered newest-first, so the LAST CUDA 13
            # profile seen is the one with the lowest driver requirement.
            if [ "${SD_CUDA_MAJOR}" = "13" ]; then
                candidate="$profile"
                candidate_driver="${SD_MIN_DRIVER}"
            fi
        done
        cuda_profile_config "${candidate:-${SD_CUDA_PROFILE_FALLBACK}}"
        echo "WARNING: compute capability ${SD_GPU_MIN_CC} needs CUDA 13, which requires"
        echo "WARNING: driver ${candidate_driver} or newer -- this host reports ${SD_DRIVER_MAJOR}.x."
        echo "WARNING: using ${SD_CUDA_PROFILE} anyway. UPDATE YOUR NVIDIA DRIVER."
        _report_cuda_profile
        return 0
    fi

    # 4b. Otherwise the driver is just too old (or unreadable) for any profile
    #     the GPU would otherwise qualify for. The fallback genuinely supports
    #     this card, so use it -- this is a warning, not a problem.
    echo "WARNING: driver ${SD_DRIVER_MAJOR}.x is below every profile's minimum, or could not be read."
    echo "WARNING: using ${SD_CUDA_PROFILE}, which supports compute capability ${SD_GPU_MIN_CC}."
    _report_cuda_profile
    return 0
}

_report_cuda_profile() {
    # Point wheel consumers at the matching per-profile directory, falling back
    # to a flat /wheels for images built before the split.
    if [ -d "/wheels/${SD_CUDA_PROFILE}" ]; then
        export SD_WHEELS_DIR="/wheels/${SD_CUDA_PROFILE}"
    elif [ -d /wheels ]; then
        export SD_WHEELS_DIR="/wheels"
    else
        export SD_WHEELS_DIR=""
    fi

    # Point runtime extension builds at the nvcc whose CUDA MAJOR matches this
    # profile's torch. Getting this wrong is the classic "The detected CUDA
    # version mismatches the version that was used to compile PyTorch" failure.
    if [ -n "${SD_CUDA_HOME}" ] && [ -d "${SD_CUDA_HOME}" ]; then
        export CUDA_HOME="${SD_CUDA_HOME}"
        export CUDA_PATH="${SD_CUDA_HOME}"
        export PATH="${SD_CUDA_HOME}/bin:${PATH}"
    fi

    echo "  torch index : ${TORCH_INDEX_URL}"
    echo "  torch spec  : ${SD_TORCH_RUNTIME_SPEC}"
    echo "  arch list   : ${TORCH_CUDA_ARCH_LIST}"
    echo "  wheels dir  : ${SD_WHEELS_DIR:-<none>}"
    echo "  cuda home   : ${CUDA_HOME:-<system default>}"
    echo -e "-------------------------------------\n"
}

# Installs the profile's torch/torchvision into the active env.
#
# Call this BEFORE a UI's own `pip install -r requirements.txt`. Most UIs list a
# bare unpinned `torch`, which resolves to the PyPI default -- currently a CUDA
# 13 build that silently excludes every pre-Turing GPU. Installing the pinned
# pair first means the later requirements.txt sees torch as already satisfied.
#
# Extra arguments are passed through to pip (e.g. --no-cache-dir).
install_torch() {
    if [ -z "${TORCH_INDEX_URL}" ]; then
        echo "install_torch: no CUDA profile selected, skipping explicit torch install."
        return 1
    fi
    echo "Installing ${SD_TORCH_RUNTIME_SPEC} from ${TORCH_INDEX_URL}"
    # --index-url, not --extra-index-url: the pytorch index must WIN over PyPI,
    # otherwise pip is free to pick the PyPI default build of the same version.
    #
    # The RUNTIME spec is used here, which includes torchaudio. Leaving torchaudio
    # to a UI's own requirements.txt lets pip take it from PyPI, where the only
    # build targets CUDA 13.0; it then refuses to load against a torch from any
    # other CUDA index ("PyTorch has CUDA version 13.2 whereas TorchAudio has
    # CUDA version 13.0") and ComfyUI cannot start.
    pip install "$@" ${SD_TORCH_RUNTIME_SPEC} --index-url "${TORCH_INDEX_URL}"
}

# Exports TORCH_COMMAND for the UIs that install torch from their OWN launcher
# rather than from a requirements.txt we control (A1111, Forge, SD.Next, Fooocus,
# kohya_ss). All of them read TORCH_COMMAND and run it verbatim, and several
# build their own venv, so install_torch into the conda env would not reach them.
#
# Without this they fall back to their built-in default, which for every one of
# them is now a CUDA 13 index -- unusable on Pascal and below.
export_torch_command() {
    if [ -z "${TORCH_INDEX_URL}" ]; then
        echo "export_torch_command: no CUDA profile selected, leaving TORCH_COMMAND alone."
        return 1
    fi
    export TORCH_COMMAND="pip install ${SD_TORCH_RUNTIME_SPEC} --index-url ${TORCH_INDEX_URL}"
    export TORCH_INDEX_URL
    echo "TORCH_COMMAND=${TORCH_COMMAND}"
}

# Prepends every NVIDIA pip-package lib directory in the ACTIVE env to
# LD_LIBRARY_PATH.
#
# Scripts used to hardcode one path, e.g.
#   .../site-packages/nvidia/cuda_nvrtc/lib
# but the layout is not stable: CUDA 12 wheels use one directory per component
# (nvidia/cuda_nvrtc/lib, nvidia/cublas/lib, ...), while the CUDA 13 wheels ship
# a consolidated nvidia/cu13/lib. A hardcoded path silently becomes a no-op on
# the other profile. Globbing whatever is actually installed works for both.
export_nvidia_lib_path() {
    local site_packages dir found=""
    site_packages=$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>/dev/null) || return 0
    [ -d "${site_packages}/nvidia" ] || return 0

    while IFS= read -r dir; do
        [ -d "$dir" ] || continue
        case ":${LD_LIBRARY_PATH}:" in *":${dir}:"*) continue ;; esac
        found="${dir}${found:+:}${found}"
    done < <(find "${site_packages}/nvidia" -maxdepth 2 -type d -name lib 2>/dev/null | sort)

    if [ -n "$found" ]; then
        export LD_LIBRARY_PATH="${found}${LD_LIBRARY_PATH:+:}${LD_LIBRARY_PATH}"
        echo "Added NVIDIA runtime libs to LD_LIBRARY_PATH: ${found}"
    fi
}

# Installs every prebuilt wheel that matches the active profile, if any exist.
# A missing wheel is not fatal -- it only means the package is unavailable or
# has to be installed from source by the UI itself.
install_profile_wheels() {
    if [ -z "${SD_WHEELS_DIR}" ] || ! compgen -G "${SD_WHEELS_DIR}/*.whl" >/dev/null; then
        echo "No prebuilt wheels for profile ${SD_CUDA_PROFILE:-<none>}, skipping."
        return 0
    fi
    echo "Installing prebuilt wheels from ${SD_WHEELS_DIR}"
    # --no-deps: these wheels declare a bare `torch` requirement, and without
    # this pip happily REPLACES the profile-matched torch we just installed.
    pip install --no-deps "${SD_WHEELS_DIR}"/*.whl
}

#Function to move folder and replace with symlink
sl_folder()     {
  echo "moving folder ${1}/${2} to ${3}/${4}"
  mkdir -p "${3}/${4}"
  if [ -d "${1}/${2}" ]; then
    rsync -r "${1}/${2}/" "${3}/${4}/" --verbose
  fi
  echo "removing folder ${1}/${2} and create symlink"
  if [ -d "${1}/${2}" ]; then
    rm -rf "${1}/${2}"
  fi
  
  # always remove previous symlink
  # b/c if user changed target locations current symlink will be incorrect
  if [ -L "${1}/${2}" ]; then
    rm "${1}/${2}"
  fi
  # create symlink
  ln -s "${3}/${4}/" "${1}"
  if [ ! -L "${1}/${2}" ]; then
    mv "${1}/${4}" "${1}/${2}"
  fi
}

clean_env()     {
if [ "$active_clean" = "1" ]; then
    echo "-------------------------------------"
    echo "Cleaning venv"
    rm -rf ${1}
    echo "Done!"
    echo -e "-------------------------------------\n"
fi
}

# Fonction pour mettre à jour un dépôt Git vers une référence spécifique
# ou vers la branche par défaut du remote, en écrasant les modifications locales
# sur les fichiers suivis, mais en conservant les fichiers ajoutés non suivis.
# Arg1: Nom de la variable d'environnement qui contient la référence Git cible (ex: "MY_APP_GIT_REF")
#       Si la variable est vide ou non définie, utilise la branche par défaut du remote.
sync_repo() {
    local git_ref_var_name="$1"
    local target_ref_value=""
    # Vérifie si la variable d'environnement passée en argument est définie ET non vide
    if [ -n "$git_ref_var_name" ] && [ -n "${!git_ref_var_name}" ]; then
        target_ref_value="${!git_ref_var_name}" # Indirection pour obtenir la valeur de la variable
    fi

    echo "Synchronizing repository in $(pwd)..."

    local remote_name=$(git remote | head -n 1)
    if [ -z "$remote_name" ]; then
        echo "Error: No remote configured for this repository. Skipping sync."
        return 1
    fi
    echo "Using remote: $remote_name"

    echo "Fetching latest changes, tags, and pruning from $remote_name..."
    git fetch "$remote_name" --prune --tags --force # --force peut aider avec certains refs conflictuels

    local final_target_ref=""

    if [ -n "$target_ref_value" ]; then
        echo "Target reference specified via $git_ref_var_name: $target_ref_value"
        # Tenter de résoudre la référence. D'abord tel quel (tag, commit, branche locale), puis comme branche distante.
        if git rev-parse --verify "$target_ref_value^{commit}" > /dev/null 2>&1; then # ^{commit} pour s'assurer que c'est un commit-ish (tags annotés)
            final_target_ref="$target_ref_value"
        elif git rev-parse --verify "$remote_name/$target_ref_value^{commit}" > /dev/null 2>&1; then
            final_target_ref="$remote_name/$target_ref_value"
        else
            echo "Warning: Specified target reference '$target_ref_value' not found locally or on remote '$remote_name'."
            echo "Falling back to default remote branch."
            # Laisse final_target_ref vide pour que la logique de fallback s'applique
        fi
    fi

    if [ -z "$final_target_ref" ]; then # Soit non spécifié, soit spécifié mais non trouvé
        local remote_head_branch_name=$(git remote show "$remote_name" | sed -n '/HEAD branch/s/.*: //p')
        if [ -z "$remote_head_branch_name" ]; then
            echo "Warning: Could not automatically determine remote HEAD branch. Attempting common names (main, master)."
            if git show-ref --verify --quiet "refs/remotes/$remote_name/main"; then
                remote_head_branch_name="main"
            elif git show-ref --verify --quiet "refs/remotes/$remote_name/master"; then
                remote_head_branch_name="master"
            else
                echo "Error: Could not determine a default branch (main/master) on remote '$remote_name'."
                # Tentative de garder la branche actuelle si elle a un remote tracking valide
                local current_branch_tracking=$(git rev-parse --abbrev-ref @{u} 2>/dev/null)
                if [ -n "$current_branch_tracking" ] && git rev-parse --verify "$current_branch_tracking^{commit}" > /dev/null 2>&1; then
                    echo "Using current branch's remote tracking: $current_branch_tracking"
                    final_target_ref="$current_branch_tracking"
                else
                    echo "Error: Cannot determine a default remote branch to reset to. Aborting sync for this repo."
                    return 1
                fi
            fi
        fi
        if [ -n "$remote_head_branch_name" ] && [ -z "$final_target_ref" ]; then # Si on a trouvé un nom de branche HEAD et que final_target_ref est toujours vide
             final_target_ref="$remote_name/$remote_head_branch_name"
        fi
        echo "Using default remote HEAD: $final_target_ref"
    fi

    if [ -z "$final_target_ref" ]; then
        echo "Error: Could not determine a final target reference. Aborting sync."
        return 1
    fi

    echo "Resetting local repository to match $final_target_ref..."
    local old_sha=$(git rev-parse HEAD 2>/dev/null || echo "no-sha")
    
    # Pour éviter les problèmes avec les branches locales et le passage en detached HEAD:
    # Si la cible finale est une branche distante (comme "origin/main"),
    # on s'assure que la branche locale correspondante est mise à jour (checkout et reset).
    # Si la cible est un tag ou un commit, on passera en detached HEAD, ce qui est normal.
    
    local current_local_branch_name=$(git rev-parse --abbrev-ref HEAD)
    # Vérifier si HEAD est détachée
    local is_detached_head="false"
    if git symbolic-ref -q HEAD >/dev/null; then # Si HEAD est une référence symbolique (une branche)
        is_detached_head="false"
    else # HEAD n'est pas une référence symbolique, donc détachée
        is_detached_head="true"
    fi


    # Est-ce que la cible est une branche distante (ex: origin/main) ?
    if [[ "$final_target_ref" == "$remote_name/"* ]]; then
        local local_branch_candidate=$(echo "$final_target_ref" | sed "s|^$remote_name/||")
        # Si on n'est pas déjà sur cette branche locale ou si on est en detached head
        if [ "$current_local_branch_name" != "$local_branch_candidate" ] || [ "$is_detached_head" == "true" ]; then
            echo "Checking out local branch '$local_branch_candidate' to track '$final_target_ref'."
            # Crée ou change de branche, et la fait pointer sur la cible distante.
            git checkout -B "$local_branch_candidate" "$final_target_ref"
        fi
        # Après le checkout -B, HEAD est sur la branche locale, pointant vers final_target_ref.
        # Un reset --hard pour s'assurer que c'est exactement final_target_ref
        git reset --hard "$final_target_ref"
    else
        # La cible est un tag, un commit, ou une branche locale déjà existante (ou inexistante, auquel cas on aura une erreur).
        # git reset --hard passera en detached HEAD si ce n'est pas une branche locale.
        # Il faut d'abord s'assurer que l'on peut faire un checkout de cette référence pour ne pas casser la branche actuelle si elle n'est pas la cible
        # Sauf si la cible est la branche actuelle
        if [ "$final_target_ref" != "$current_local_branch_name" ] || [ "$is_detached_head" == "true" ]; then
             git checkout "$final_target_ref" # Ceci va passer en detached HEAD si final_target_ref est un tag/commit
        fi
        git reset --hard "$final_target_ref" # Appliquer le reset sur la (potentiellement nouvelle) HEAD
    fi
    
    local new_sha=$(git rev-parse HEAD 2>/dev/null || echo "no-sha")

    if [ "$old_sha" != "$new_sha" ]; then
        echo "Repository updated. HEAD is now at $new_sha."
#        export active_clean=1 # Signaler que le venv pourrait aussi avoir besoin d'être nettoyé
    else
        echo "Repository HEAD ($new_sha) is unchanged or reset to the same state. Local modifications to tracked files (if any) have been reset."
        # Si des modifs locales ont été écrasées, le statut de git diff --staged sera vide.
        # On peut considérer active_clean=1 ici aussi si on veut être sûr
#        if ! git diff-index --quiet HEAD --; then # S'il reste des modifs (non suivies par ex)
#             : # Ne rien faire de spécial, juste pour illustrer
#        else # Si le repo est propre après reset, c'est que les modifs sur fichiers suivis ont été annulées
#             export active_clean=1
#       fi
    fi

    echo "Synchronization complete. Tracked files match $final_target_ref."
    echo "Untracked files (newly added local files) have been preserved."
}

# L'ancienne fonction check_remote est maintenant remplacée en esprit par sync_repo.
check_remote() {
    # Le premier argument de check_remote doit être le nom de la variable d'env pour la ref Git
    # ex: check_remote "FORGE_GIT_REF"
    # Si aucun argument n'est fourni, on passe une chaîne vide à sync_repo,
    # ce qui signifie que sync_repo utilisera la branche par défaut du remote.
    sync_repo "$1"
}


# Fonction récursive pour installer les requirements.txt
#install_requirements() {
#    local directory="$1"
#    local requirements_file="$directory/requirements.txt"

#    if [ -f "$requirements_file" ]; then
#        echo "Installation des dépendances dans $directory ..."
#        pip install -r "$requirements_file"
#        echo "Dépendances installées avec succès dans $directory."
#    fi

#    # Parcours récursif des sous-dossiers
#    for subdir in "$directory"/*; do
#        if [ -d "$subdir" ]; then
#            install_requirements "$subdir"
#        fi
#    done
#}
install_requirements() {
    local directory="$1"
    local requirements_file="$directory/requirements.txt"

    if [ -f "$requirements_file" ]; then
        echo "Installation des dépendances dans $directory ..."
        pip install -r "$requirements_file"
        echo "Dépendances installées avec succès dans $directory."
    fi

    # Parcours des sous-dossiers du premier niveau uniquement
    for subdir in "$directory"/*; do
        if [ -d "$subdir" ]; then
            local subdir_requirements_file="$subdir/requirements.txt"
            if [ -f "$subdir_requirements_file" ]; then
                echo "Installation des dépendances dans $subdir ..."
                pip install -r "$subdir_requirements_file"
                echo "Dépendances installées avec succès dans $subdir."
            fi
        fi
    done
}
# -----------------------------------------------------------------------------
# Run the profile selection once, at source time.
#
# Every NN.sh sources this file at line 2, so doing it here means the profile
# variables are available to all of them without touching each script's header.
# The guard keeps it to a single nvidia-smi call per container start.
# -----------------------------------------------------------------------------
if [ -z "${SD_CUDA_PROFILE_RESOLVED}" ]; then
    detect_cuda_profile || true
    export SD_CUDA_PROFILE_RESOLVED=1
fi
