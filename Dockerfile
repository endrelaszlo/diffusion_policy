# CUDA runtime base (GPU libraries in-container; driver stays on the host)
FROM nvidia/cuda:11.6.2-cudnn8-runtime-ubuntu20.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    MAMBA_ROOT_PREFIX=/opt/micromamba \
    PATH=/opt/micromamba/bin:$PATH

# System deps (incl. MuJoCo deps noted in the repo README for Ubuntu 20.04)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git \
    libosmesa6-dev libgl1-mesa-glx libglfw3 patchelf \
    build-essential pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install micromamba (fast conda replacement)
RUN curl -L https://micro.mamba.pm/api/micromamba/linux-64/latest | \
    tar -xvj -C /usr/local/bin/ --strip-components=1 bin/micromamba

WORKDIR /workspace

# Copy environment definition and create env
COPY conda_environment.yaml /tmp/conda_environment.yaml
RUN micromamba create -y -n robodiff -f /tmp/conda_environment.yaml && \
    micromamba clean -a -y

# Copy project and install
COPY . /workspace
RUN micromamba run -n robodiff python -m pip install --no-cache-dir -e .

# Default shell context inside env
SHELL ["micromamba", "run", "-n", "robodiff", "/bin/bash", "-lc"]

# A safe default command (override in `docker run ...`)
CMD ["python", "-c", "import diffusion_policy; print('diffusion_policy import OK')"]
