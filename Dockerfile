# syntax=docker/dockerfile:1.7
# =============================================================================
# Runtime image.
#
# This no longer builds FROM the buildbase. The buildbase is now a `FROM scratch`
# artifact image containing only /wheels (see Dockerfile.buildbase), and it is
# pulled in with COPY --from below. Consequences:
#
#   - Rebuilding this image no longer drags a multi-GB compile base along.
#   - Rebuilding the wheels no longer invalidates this image's layers.
#   - One runtime image carries the wheels for EVERY CUDA profile and picks the
#     matching set at container start (see detect_cuda_profile in functions.sh).
#
# -----------------------------------------------------------------------------
# WHERE THE WHEELS COME FROM
#
# The default is the UPSTREAM namespace, so a plain `docker build` in a clean
# checkout uses upstream's published wheels and no fork is baked into the file.
#
# Forks do not need to edit this. The publish workflow detects that it is running
# in a fork, and if that fork has published its own wheels images it passes them
# in via WHEELS_IMAGE automatically -- otherwise it falls back to upstream. So a
# fork gets its own wheels as soon as it runs the build-wheels workflow once, and
# keeps working before that.
#
# To point a manual build at your own wheels, one arg switches all three:
#   docker build --build-arg WHEELS_IMAGE=ghcr.io/<you>/sd-wheels .
#
# Or override a single profile, e.g. to test a locally built one:
#   docker build --build-arg WHEELS_CU130=sd-wheels:cu130-test .
# =============================================================================

ARG BASE_IMAGE=ghcr.io/linuxserver/baseimage-kasmvnc:ubuntunoble

# Repository holding the per-profile wheel artifact images.
ARG WHEELS_IMAGE=ghcr.io/grokuku/sd-wheels

# Per-profile wheel artifact images. Tags encode the coordinate that invalidates
# them, so a torch bump means a new tag rather than a silent ABI mismatch.
ARG WHEELS_CU126=${WHEELS_IMAGE}:cu126
ARG WHEELS_CU130=${WHEELS_IMAGE}:cu130
ARG WHEELS_CU132=${WHEELS_IMAGE}:cu132

FROM ${WHEELS_CU126} AS wheels-cu126
FROM ${WHEELS_CU130} AS wheels-cu130
FROM ${WHEELS_CU132} AS wheels-cu132

FROM ${BASE_IMAGE}

# Copy s6-overlay and custom service configuration
COPY docker/root/ /

# --- Environment Variables ---
ENV DEBIAN_FRONTEND=noninteractive
ENV WEBUI_VERSION=01
ENV CUSTOM_PORT=3000
ENV BASE_DIR=/config \
    SD_INSTALL_DIR=/opt/sd-install \
    XDG_CACHE_HOME=/config/temp

# Set compiler for any potential runtime compilations.
#
# TORCH_CUDA_ARCH_LIST is deliberately NOT set here any more. It is per-profile
# now and gets exported at container start by detect_cuda_profile(); a build-time
# value would be wrong for two of the three profiles and would silently override
# the correct one.
ENV CC=/usr/bin/gcc-13
ENV CXX=/usr/bin/g++-13

# --- System & Package Installation ---
RUN apt-get update -q && \
    # Install system dependencies for Ubuntu 24.04, removing conflicting/obsolete packages
    apt-get install -y -q=2 curl \
    software-properties-common \
    wget \
    gnupg \
    mc \
    bc \
    nano \
    rsync \
    libxft2 \
    xvfb \
    cmake \
    build-essential \
    ffmpeg \
    gcc-13 \
    g++-13 \
    git && \
    # Remove any conflicting system Python to ensure Conda's version is used
    apt-get purge python3 -y && \
    # Install CUDA Toolkit for Ubuntu 24.04
    cd /tmp/ && \
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && \
    # Ajoute le dépôt Microsoft pour dotnet
    wget https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb && \
    dpkg -i packages-microsoft-prod.deb && \
    rm packages-microsoft-prod.deb && \
    apt-get update && \
    # The CUDA 13 toolkit serves the cu130 and cu132 profiles. nvcc only has to
    # agree with torch on the CUDA MAJOR version -- a minor difference (13.0
    # toolkit vs a cu132 torch) is a warning, not an error.
    apt-get -y install cuda-toolkit-13-0 dotnet-sdk-8.0 && \
    # ...plus a minimal CUDA 12 compiler set for the cu126 profile. Without it a
    # Pascal / old-driver user who triggers a runtime extension build (some
    # ComfyUI custom nodes compile on install) hits "The detected CUDA version
    # (13.0) mismatches the version that was used to compile PyTorch (12.6)".
    # This is nvcc + headers only, not another full ~7 GB toolkit.
    apt-get -y install cuda-nvcc-12-6 cuda-cudart-dev-12-6 cuda-cccl-12-6 && \
    # Clean up package cache
    apt autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# --- openbox-session placeholder ---
# `apt-get purge python3` above does not only remove python: openbox depends on
# python3, so apt drags it out too and /usr/bin/openbox-session disappears with
# it. KasmVNC's startwm.sh expects that file, and without it the session service
# can restart-loop.
#
# entry.sh already tries to paper over this at runtime, but it CANNOT work:
# docker/root/etc/s6-overlay/s6-rc.d/svc-app/run execs it via `s6-setuidgid abc`,
# so it runs as the unprivileged `abc` user and cannot write into /usr/bin. That
# is the source of
#     /entry.sh: line 31: /usr/bin/openbox-session: Permission denied
#     chmod: cannot access '/usr/bin/openbox-session': No such file or directory
#
# Creating it here instead fixes it at the only point where we are still root.
# entry.sh's own check then finds the file and skips its (doomed) write.
RUN if [ ! -e /usr/bin/openbox-session ]; then \
      printf '#!/bin/bash\nexit 0\n' > /usr/bin/openbox-session && \
      chmod +x /usr/bin/openbox-session && \
      echo "created placeholder /usr/bin/openbox-session"; \
    else \
      echo "/usr/bin/openbox-session survived the apt purge, leaving it alone"; \
    fi

# --- Prebuilt CUDA wheels, one directory per profile ---
# functions.sh:_report_cuda_profile points SD_WHEELS_DIR at the matching one.
# Installing the wrong set is not a subtle failure: these are compiled C++
# extensions linked against one specific libtorch, so a mismatch is an
# ImportError at best and a segfault at worst.
COPY --from=wheels-cu126 /wheels /wheels/cu126
COPY --from=wheels-cu130 /wheels /wheels/cu130
COPY --from=wheels-cu132 /wheels /wheels/cu132

# --- Application Setup ---
# Create application directories
RUN mkdir -p ${BASE_DIR}/temp ${SD_INSTALL_DIR} ${BASE_DIR}/outputs

# Copy WebUI parameters
ADD parameters/* ${SD_INSTALL_DIR}/parameters/

RUN mkdir -p /root/defaults

# Copy and set permissions for all launch scripts.
# This glob also picks up cuda-profiles.sh, which functions.sh sources from /.
COPY --chown=abc:abc *.sh ./
RUN chmod +x /entry.sh

# --- User and Environment Setup ---
# Set home directory for the application user
ENV XDG_CONFIG_HOME=/home/abc
ENV HOME=/home/abc
RUN mkdir /home/abc && \
    chown -R abc:abc /home/abc

# Install Miniforge for Python environment management (uses conda-forge by default)
RUN cd /tmp && \
    # URL for Miniforge installer
    wget https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh && \
    # Install Miniforge directly into the path expected by all launch scripts
    bash Miniforge3-Linux-x86_64.sh -b -p /home/abc/miniconda3 && \
    rm Miniforge3-Linux-x86_64.sh && \
    # Set final ownership for application folders
    chown -R abc:abc /root && \
    chown -R abc:abc ${SD_INSTALL_DIR} && \
    chown -R abc:abc /home/abc

# Expose default ports
EXPOSE 9000/tcp
EXPOSE 3000/tcp
