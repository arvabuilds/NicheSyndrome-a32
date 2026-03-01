# Base: Ubuntu 22.04 — matches the GitHub Actions runner exactly
# so builds behave identically in both environments
FROM ubuntu:22.04

# Prevent interactive prompts during apt installs
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install all kernel build dependencies in a single layer
# Combining into one RUN minimizes image layer count
RUN apt-get update && apt-get install -y \
    # Core build tools
    bc \
    bison \
    build-essential \
    ccache \
    curl \
    flex \
    git \
    make \
    # Cross-compilation support
    g++-multilib \
    gcc-multilib \
    # Kernel-specific requirements
    libelf-dev \
    libncurses-dev \
    libssl-dev \
    lld \
    pahole \
    # Scripting and compression
    python3 \
    python3-pip \
    zstd \
    # Packaging tools
    zip \
    unzip \
    # Useful for interactive debugging
    vim \
    nano \
    htop \
    file \
    wget \
    # SSH server (required for external SSH access)
    openssh-server \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Configure ccache
ENV CCACHE_DIR=/workspace-cache/ccache
ENV USE_CCACHE=1
ENV CCACHE_MAXSIZE=5G

# Set up SSH server directory
RUN mkdir /var/run/sshd

# The actual user setup and toolchain download happens in setup.sh
# at Codespace creation time, not here — that way toolchains don't
# bloat the image layer and can be updated without rebuilding the image

WORKDIR /workspaces
