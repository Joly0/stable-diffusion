#!/bin/bash
source /functions.sh

export PATH="/home/abc/miniconda3/bin:$PATH"
export SD05_DIR=${BASE_DIR}/05-comfy-ui

echo "Install and run Comfy-UI"
mkdir -p ${SD05_DIR}
mkdir -p /config/outputs/05-comfy-ui

# Copy default launch parameters if they don't exist
if [ ! -f "$SD05_DIR/parameters.txt" ]; then
    cp -v "${SD_INSTALL_DIR}/parameters/05.txt" "$SD05_DIR/parameters.txt"
fi

# Install or update the main ComfyUI repository
if [ ! -d "${SD05_DIR}/ComfyUI/.git" ]; then
    echo "Cloning ComfyUI repository..."
    git clone https://github.com/comfyanonymous/ComfyUI.git "${SD05_DIR}/ComfyUI"
    cd "${SD05_DIR}/ComfyUI"
else
    echo "Existing ComfyUI repository found. Synchronizing..."
    cd "${SD05_DIR}/ComfyUI"
    check_remote "GIT_REF"
fi

# Install or update the ComfyUI-Manager custom node
mkdir -p "${SD05_DIR}/ComfyUI/custom_nodes"
if [ ! -d "${SD05_DIR}/ComfyUI/custom_nodes/ComfyUI-Manager/.git" ]; then
    echo "Cloning ComfyUI-Manager repository..."
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git "${SD05_DIR}/ComfyUI/custom_nodes/ComfyUI-Manager"
    cd "${SD05_DIR}/ComfyUI/custom_nodes/ComfyUI-Manager"
else
    echo "Existing ComfyUI-Manager repository found. Synchronizing..."
    cd "${SD05_DIR}/ComfyUI/custom_nodes/ComfyUI-Manager"
    check_remote "GIT_REF"
fi

# Clean the Conda environment if required
clean_env ${SD05_DIR}/env

# Create the Conda environment if it doesn't exist
if [ ! -d ${SD05_DIR}/env ]; then
    conda create -p ${SD05_DIR}/env -y
fi

# Activate the environment and install base packages
source activate ${SD05_DIR}/env
conda install -n base conda-libmamba-solver -y
conda install -c conda-forge git python=3.12 pip gxx libcurand --solver=libmamba -y
conda install -c nvidia cuda-cudart --solver=libmamba -y

# Install dependencies for custom nodes if a full clean was performed
if [ "$active_clean" = "1" ]; then
    echo "-------------------------------------"
    echo "Install Custom Nodes Dependencies"
    install_requirements ${SD05_DIR}/ComfyUI/custom_nodes
    echo "Done!"
    echo -e "-------------------------------------\n"
fi

# Remove old venv if it still exists (legacy)
if [ -d ${SD05_DIR}/venv ]; then
    rm -rf ${SD05_DIR}/venv
fi

# Symlink shared models folders into the ComfyUI directory
sl_folder ${SD05_DIR}/ComfyUI/models checkpoints ${BASE_DIR}/models stable-diffusion
sl_folder ${SD05_DIR}/ComfyUI/models hypernetworks ${BASE_DIR}/models hypernetwork
sl_folder ${SD05_DIR}/ComfyUI/models loras ${BASE_DIR}/models lora
sl_folder ${SD05_DIR}/ComfyUI/models vae ${BASE_DIR}/models vae
sl_folder ${SD05_DIR}/ComfyUI/models vae_approx ${BASE_DIR}/models vae_approx
sl_folder ${SD05_DIR}/ComfyUI/models embeddings ${BASE_DIR}/models embeddings
sl_folder ${SD05_DIR}/ComfyUI/models upscale_models ${BASE_DIR}/models upscale
sl_folder ${SD05_DIR}/ComfyUI/models clip_vision ${BASE_DIR}/models clip_vision
sl_folder ${SD05_DIR}/ComfyUI/models clip ${BASE_DIR}/models clip
sl_folder ${SD05_DIR}/ComfyUI/models controlnet ${BASE_DIR}/models controlnet
sl_folder ${SD05_DIR}/ComfyUI/models t5 ${BASE_DIR}/models t5
sl_folder ${SD05_DIR}/ComfyUI/models unet ${BASE_DIR}/models unet

# Install ComfyUI's Python requirements
cd ${SD05_DIR}/ComfyUI
pip install --upgrade pip

# Install torch FIRST, from the index matching this machine's GPU and driver.
#
# ComfyUI's requirements.txt lists a bare, unpinned `torch`. Left alone that
# resolves to the PyPI default build, which is currently CUDA 13 -- it needs
# driver >= 580 and has no kernels below sm_75, so every Pascal/Maxwell/Volta
# user gets a torch that cannot run on their card. Installing the profile's
# torch first means the requirements.txt below sees it as already satisfied.
install_torch

pip install -r requirements.txt

# Install custom user requirements if specified
if [ -f ${SD05_DIR}/requirements.txt ]; then
    pip install -r ${SD05_DIR}/requirements.txt
fi

# Install pre-compiled wheels matching the selected profile.
#
# This was `pip install /wheels/*.whl`, which installed one fixed set built
# against one fixed torch. These are compiled C++ extensions linked against a
# specific libtorch, so the wrong set is an ImportError, and pip was also free
# to pull its own torch in as a dependency and downgrade the one just installed.
# install_profile_wheels picks /wheels/<profile> and passes --no-deps.
install_profile_wheels

# spconv publishes no build newer than cu126 (there is no spconv-cu128/130), so
# this stays on cu126 for every profile. It bundles its own CUDA runtime, so it
# coexists with a CUDA 13 torch.
pip install plyfile \
    tqdm \
    spconv-cu126 \
    llama-cpp-python \
    logger

# SageAttention: install the compiled v2/v2++ wheel from /wheels when this
# profile has one. Only fall back to the PyPI package (1.0.6, Triton-only, no
# compiled kernels) when it does not.
if ! python -c "import sageattention" >/dev/null 2>&1; then
    pip install sageattention
fi

pip install --upgrade diffusers[torch]

# Launch ComfyUI
cd ${SD05_DIR}/ComfyUI
CMD="python3 main.py"
while IFS= read -r param; do
    if [[ $param != \#* ]]; then
        CMD+=" ${param}"
    fi
done < "${SD05_DIR}/parameters.txt"
eval $CMD
sleep infinity