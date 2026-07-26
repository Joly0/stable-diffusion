# Easy Image Generation

[![Docker Pulls](https://img.shields.io/docker/pulls/holaflenain/stable-diffusion)](https://hub.docker.com/r/holaflenain/stable-diffusion)

The goal of this docker container is to provide an easy way to run different WebUI/projects and other tools related to Image Generation (mostly stable-diffusion).

# Projects 

Please consult each respective website for a comprehensive description and usage guidelines.  
| WEBUI | Name              |                                                                                                                                              |                                                         |
|-------|-------------------|----------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------|
| 01    | easy diffusion    | The easiest way to install and use Stable Diffusion on your computer.                                                                        | https://github.com/easydiffusion/easydiffusion          |
| 02    | automatic1111     | A browser interface based on Gradio library for Stable Diffusion                                                                             | https://github.com/AUTOMATIC1111/stable-diffusion-webui |
| 02.forge    | forge     | An optimized fork of Automatic1111                                                                             | https://github.com/lllyasviel/stable-diffusion-webui-forge |
| 03    | InvokeAI          | InvokeAI is a leading creative engine for Stable Diffusion models                                                                            | https://github.com/invoke-ai                            |
| 04    | SD.Next           | This project started as a fork from Automatic1111 WebUI and it grew significantly                                                            | https://github.com/vladmandic/automatic                 |
| 05    | ComfyUI           | A powerful and modular stable diffusion GUI and backend                                                                                      | https://github.com/comfyanonymous/ComfyUI               |
| 06    | Fooocus           | Fooocus is a rethinking of Stable Diffusion and Midjourney’s designs                                                                         | https://github.com/lllyasviel/Fooocus                   |
| 07    | SwarmUI       | A Modular Stable Diffusion Web-User-Interface, with an emphasis on making powertools easily accessible, high performance, and extensibility. | https://github.com/mcmonkeyprojects/SwarmUI           |
| 50    | Lama Cleaner      | A free and open-source inpainting tool powered by SOTA AI model.                                                                             | https://github.com/Sanster/lama-cleaner                 |
| 51    | FaceFusion        | Next generation face swapper and enhancer                                                                                                    | https://github.com/facefusion/facefusion                |
| 70    | Kohya             | Kohya's GUI provides a Windows-focused Gradio GUI for Kohya's Stable Diffusion trainers                                                      | https://github.com/bmaltais/kohya_ss                    |
| 71    | Fluxgym             | Dead simple web UI for training FLUX LoRA with LOW VRAM (12GB/16GB/20GB) support                                                      | https://github.com/cocktailpeanut/fluxgym                    |
| 72    | OneTrainer             | OneTrainer is a one-stop solution for all your stable diffusion training needs                                                      | https://github.com/Nerogar/OneTrainer                    |
| 73    | AI Toolkit        | A collection of various tools for AI-related tasks.                                                                                  | https://github.com/ostris/ai-toolkit                    |
  

# Usage

Unraid template available on [superboki's Repository](https://github.com/superboki/UNRAID-FR/tree/main/stable-diffusion-advanced) (search stable-diffusion in community apps)

## Choosing a Project

```
docker compose --profile easy-diffusion up    # http://<server_ip>:9001
docker compose --profile automatic up         # http://<server_ip>:9002
docker compose --profile forge up             # http://<server_ip>:9022
docker compose --profile invoke-ai up         # http://<server_ip>:9003
docker compose --profile sd-next up           # http://<server_ip>:9004
docker compose --profile comfy-ui up          # http://<server_ip>:9005
docker compose --profile fooocus up           # http://<server_ip>:9006
docker compose --profile swarmui up           # http://<server_ip>:9007
docker compose --profile lama-cleaner up      # http://<server_ip>:9050
docker compose --profile face-fusion up       # http://<server_ip>:9051
docker compose --profile kohya up             # http://<server_ip>:9070
docker compose --profile fluxgym up           # http://<server_ip>:9071
docker compose --profile onetrainer up        # http://<server_ip>:9072
docker compose --profile ai-toolkit up        # http://<server_ip>:9073

```

or 
( Although not recommended as it will requires significant system resources, 64GB+ system memory and at bare minimum 16GB VRAM card, you have been warned! ) 

```
docker compose up       # to run all the services at once
```

## Make

alternatively you can use make to start and stop the services

there are two variations 

```
# will start the service detached from the terminal (running in the background)
make start <profile_name> 

# will start the service and leave its output attached to the terminal
make up <profile_name>
```
Here is a complete list for starting services
```
make start easy-diffusion    # http://<server_ip>:9001
make start automatic         # http://<server_ip>:9002
make start forge             # http://<server_ip>:9022
make start invoke-ai         # http://<server_ip>:9003
make start sd-next           # http://<server_ip>:9004
make start comfy-ui          # http://<server_ip>:9005
make start fooocus           # http://<server_ip>:9006
make start swarmui           # http://<server_ip>:9007
make start lama-cleaner      # http://<server_ip>:9050
make start face-fusion       # http://<server_ip>:9051
make start kohya             # http://<server_ip>:9070
make start fluxgym           # http://<server_ip>:9071
make start onetrainer        # http://<server_ip>:9072
make start ai-toolkit        # http://<server_ip>:9073
```


## Directory Structure

Each interface has its own folder :  
- **stable-diffusion** folder tree:  
├── 01-easy-diffusion  
├── 02-sd-webui  
...  
├── 51-facefusion   
├── 70-kohya   
└── models  

Models, VAEs, and other files are located in the shared models directory and symlinked for each user interface, excluding InvokeAI:    
- **Models** folder tree :  
├── embeddings  
├── hypernetwork  
├── lora  
├── stable-diffusion  
├── upscale  
└── vae  
  
By default, each user interface will save data in its own directory, which is automatically created during the initial installation of the UI. To modify the storage path, you can edit the 'parameters.txt' file for InvokeAI and ComfyUI, while for the others, it can be adjusted via the WebUI.  
- **Outputs** folder tree :  
├── 01-Easy-Diffusion  
├── 02-sd-webui  
...   
├── 20-kubin   
├── 50-lama-cleaner   
└── 51-facefusion   

## Project Notes

VoltaML (08) and Kubin (20) have been excluded to maintain focus on Stable-Diffusion for image generation.

General changes are listed below and **specified in notes if they apply.** Specific project modifications are listed below these.

###### Clean Environment

Auto-clean of environment when a project is behind the remote branch is only launched if varaible CLEAN_ENV is set to true.  
To trigger a clean, now you have to delete the file names "Delete_this_file_to_clean_virtual_env_and_dependencies_at_next_launch" in the root folder.
This applies to the launching project only.

#### Access rights reset

If something went wrong and you can't access certain files, you can reset access rights by deleting the file named 'Delete_this_file_to_reset_access_rights_at_next_launch' in the root folder.   
This applies to all the /config folder.   

#### CUDA profiles (GPU compatibility)

One image serves every NVIDIA GPU. At container start the launch scripts read the
lowest compute capability across your GPUs plus your driver version, and select a
**CUDA profile**; each UI then installs a torch built for that profile. This costs
nothing extra — every UI already downloaded torch on first launch, it just comes
from a different index now.

| Profile | GPUs | Min driver | torch build |
|---------|------|-----------|-------------|
| `cu126` | Maxwell → Hopper (GTX 750 … GTX 10xx, RTX 20/30/40xx, A100, H100) | 525 | `+cu126` |
| `cu130` | Turing → Blackwell (RTX 20xx … RTX 50xx) | 580 | `+cu130` |

A `cu132` profile is defined but **not enabled**: PyTorch publishes no
`torchaudio` for cu132, and ComfyUI imports torchaudio unconditionally, so it
cannot start there. Nothing is lost — cu130 and cu132 have identical GPU arch
lists, so cu132 covers no card that cu130 does not.

Why more than one: CUDA 13 dropped Maxwell, Pascal and Volta outright, and PyTorch
dropped them from every build newer than `cu126`. So `cu126` is the only remaining
torch with GTX 10xx kernels — and it has no Blackwell kernels, so RTX 50xx needs
`cu13x`. The **same torch release** is published on all three indexes, so an old
card does not mean an old torch. Only the CUDA runtime differs.

Notes:
- On a multi-GPU machine the **weakest** card decides, since all UIs share one
  torch install per environment.
- A Blackwell card on a pre-580 driver is warned about and pushed to `cu130`
  anyway — `cu126` has no kernels that card can run. Update your driver.
- No GPU visible falls back to `cu126`.

Override the autodetect if you need to:

```
docker run -e SD_CUDA_PROFILE=cu126 ...
```

The startup log prints the selected profile, the index URL and the reason. Profile
definitions live in [`cuda-profiles.sh`](/cuda-profiles.sh) — it is the single
source of truth shared by the runtime scripts and CI.

#### Building the images

Two independent images:

- **`Dockerfile.buildbase`** produces prebuilt CUDA wheels (SageAttention 2/2++,
  diso, nvdiffrast, kaolin) for one profile. Its final stage is `FROM scratch`, so
  the result is a ~200 MB artifact holding only `/wheels` — it cannot be run, only
  `COPY --from`'d. flash-attention is *downloaded* rather than compiled
  ([`scripts/fetch-flash-attn.sh`](/scripts/fetch-flash-attn.sh)).
- **`Dockerfile`** is the runtime image. It pulls all three wheel sets in and picks
  the matching one at start.

CI ([`build-wheels.yml`](/.github/workflows/build-wheels.yml)) runs one job per
(profile, package) on free hosted runners, so no single job has to fit every
compile into one memory/time budget. It only triggers on `workflow_dispatch` and on
changes to the files that actually invalidate wheels.

SageAttention is shipped as more than one build. Some CUDA architectures cannot
share a wheel — sm_90 (Hopper) uses TMA/mbarrier instructions that cannot be
compiled for older targets, and upstream applies one arch list to every
extension — so those are built separately into `/wheels/<profile>/<variant>/`
and chosen at container start. The choice comes from CUDA binary compatibility
(a cubin for `X.y` runs on `X.z` when `z >= y`), not a hardcoded GPU list, so
supporting a future exclusive architecture is a `cuda-profiles.sh` entry rather
than a code change.

GPUs older than sm_80 get no SageAttention wheel at all — it has no kernels for
them, and installing one would make the UI select it and fail on every attention
call rather than falling back cleanly.

Run the profile-selection tests with `./tests/test-cuda-profiles.sh`.

##### Forks

Nothing is hardcoded to a particular GitHub account. `Dockerfile` defaults to the
upstream wheels namespace, and forks pick up their own automatically:

- `build-wheels.yml` always publishes to **your** namespace
  (`ghcr.io/<your-account>/sd-wheels`), derived from `github.repository_owner`.
- `publishImage.yml` checks whether your namespace has a complete set of wheels
  images. If it does, it builds against them; if not, it falls back to the
  upstream default. So a fresh fork works straight away on upstream's wheels and
  switches to its own the first time you run the wheels workflow.

For a manual build, one argument switches all profiles:

```
docker build --build-arg WHEELS_IMAGE=ghcr.io/<you>/sd-wheels -t stable-diffusion .
```

#### A note on development
Starting from version 4.0, this project is being developed with the assistance of Google's Gemini.

# History

See [**Changelog**](/CHANGELOG.md)
  
# Support

Support for the container available here : https://forums.unraid.net/topic/143645-support-stable-diffusion-advanced/  
Support for the WebUIs available on their respective pages.

## Troubleshooting

First thing to try when a UI refuse to launch, remove the cache and the numbered folder (ex :02-sd-webui ) then relaunch the container  
