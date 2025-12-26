# CUDA runtime base (GPU libraries in-container; driver stays on the host)
# Multi-stage build keeps build tooling out of the final image.
FROM nvidia/cuda:11.6.2-cudnn8-runtime-ubuntu20.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    MAMBA_ROOT_PREFIX=/opt/micromamba \
    PATH=/opt/micromamba/bin:$PATH \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Build deps (headers/compilers needed for some pip wheels)
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
    rm -rf /root/.cache/pip /tmp/pip-* /tmp/pip-build-* || true && \
    micromamba clean -a -y && \
    find /opt/micromamba -type f -name '*.a' -delete || true && \
    find /opt/micromamba -type f -name '*.pyc' -delete || true && \
    find /opt/micromamba -type d -name '__pycache__' -prune -exec rm -rf {} + || true

# Copy project and install
COPY . /workspace
RUN micromamba run -n robodiff python -m pip install --no-cache-dir -e . && \
    rm -rf /root/.cache/pip /tmp/pip-* /tmp/pip-build-* || true


FROM nvidia/cuda:11.6.2-cudnn8-runtime-ubuntu20.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    MAMBA_ROOT_PREFIX=/opt/micromamba \
    PATH=/opt/micromamba/bin:$PATH \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Runtime deps only (no compilers / headers)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl wget \
    git \
    openssh-server openssh-client \
    sudo \
    zsh tmux \
    nvtop \
    less vim-tiny \
    unzip \
    libosmesa6 libgl1-mesa-glx libglfw3 patchelf \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/micromamba /usr/local/bin/micromamba
COPY --from=builder /opt/micromamba /opt/micromamba

# Compatibility: if micromamba starts without MAMBA_ROOT_PREFIX, it defaults to
# /root/.local/share/mamba. Point that location at our baked prefix so
# `micromamba activate robodiff` works reliably.
RUN mkdir -p /root/.local/share && \
    rm -rf /root/.local/share/mamba && \
    ln -s /opt/micromamba /root/.local/share/mamba

WORKDIR /workspace
COPY --from=builder /workspace /workspace

# Make interactive shells auto-activate the robodiff env
RUN printf '%s\n' \
    'eval "$(micromamba shell hook --shell bash)"' \
    'micromamba activate robodiff' \
    > /etc/profile.d/robodiff.sh && \
    chmod 0644 /etc/profile.d/robodiff.sh && \
    echo 'source /etc/profile.d/robodiff.sh' >> /etc/bash.bashrc

# SSH setup
# - Key auth only by default (RunPod provides SSH keys on the Pod; we can also accept keys via env vars)
# - Root-only by default (key auth); you can add a non-root user in derived images if desired
RUN mkdir -p /var/run/sshd && \
    mkdir -p /root/.ssh && \
    chmod 700 /root/.ssh && \
    sed -i 's@^#\?PasswordAuthentication .*@PasswordAuthentication no@g' /etc/ssh/sshd_config && \
    sed -i 's@^#\?KbdInteractiveAuthentication .*@KbdInteractiveAuthentication no@g' /etc/ssh/sshd_config && \
    sed -i 's@^#\?PubkeyAuthentication .*@PubkeyAuthentication yes@g' /etc/ssh/sshd_config && \
    sed -i 's@^#\?PermitRootLogin .*@PermitRootLogin prohibit-password@g' /etc/ssh/sshd_config && \
    sed -i 's@^#\?AllowAgentForwarding .*@AllowAgentForwarding yes@g' /etc/ssh/sshd_config && \
    sed -i 's@^#\?AllowTcpForwarding .*@AllowTcpForwarding yes@g' /etc/ssh/sshd_config && \
    printf "\nAllowUsers root\nClientAliveInterval 60\nClientAliveCountMax 10\n" >> /etc/ssh/sshd_config && \
    printf '%s\n' 'Defaults env_keep += "SSH_AUTH_SOCK"' > /etc/sudoers.d/020-ssh-agent-forwarding && \
    chmod 0440 /etc/sudoers.d/020-ssh-agent-forwarding

EXPOSE 22

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Default shell context inside env
SHELL ["micromamba", "run", "-n", "robodiff", "/bin/bash", "-lc"]

# Default command keeps container alive for SSH (RunPod can override this)
CMD ["bash", "-lc", "sleep infinity"]
