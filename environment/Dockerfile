# === BEGIN realm base (do not edit) ===
FROM --platform=linux/amd64 node:24-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# m1-nproc-pin: Daytona nproc is the host (32/48/64), not the 1-4 vCPU
# sandbox. Vendored Makefiles/CMake call $(nproc); wrap it here so those
# calls stay at 2 jobs (cc1plus ~1 GB, safe on 4 GB boxes). Compile with
# cmake --build -j"$M1_BUILD_JOBS" / make -j"$M1_BUILD_JOBS".
ARG M1_BUILD_JOBS=2
ENV M1_BUILD_JOBS=${M1_BUILD_JOBS} \
    CMAKE_BUILD_PARALLEL_LEVEL=${M1_BUILD_JOBS} \
    MAKEFLAGS=-j${M1_BUILD_JOBS} \
    CARGO_BUILD_JOBS=${M1_BUILD_JOBS} \
    GOMAXPROCS=${M1_BUILD_JOBS} \
    NPROC=${M1_BUILD_JOBS}
RUN mkdir -p /usr/local/bin \
 && printf '%s\n' '#!/bin/sh' "echo ${M1_BUILD_JOBS}" > /usr/local/bin/nproc \
 && chmod 755 /usr/local/bin/nproc

# Core tooling present in every task image. Node.js comes from the base image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl wget \
        git patch \
        ripgrep fd-find jq less file unzip \
        vim sudo procps \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd

# Python (default language, uv-managed; uv also drives dependency installs).
ENV UV_PYTHON_INSTALL_DIR=/opt/python
RUN curl -LsSf https://astral.sh/uv/0.11.13/install.sh | UV_INSTALL_DIR=/usr/local/bin sh \
 && uv python install 3.13 \
 && ln -sf "$(uv python find 3.13)" /usr/local/bin/python3 \
 && ln -sf /usr/local/bin/python3 /usr/local/bin/python

# Agent CLI, baked at build time (network is available during the build).
# opencode-ai installs under the base image's node to /usr/local/bin, so
# `opencode` is on PATH at run time regardless of nvm — and the agent phase
# needs no network to obtain the binary. harbor still runs its own opencode
# install at trial start; baking it makes that a no-op and sidesteps the
# node:24-vs-nvm-node-22 PATH mismatch that otherwise leaves opencode
# unresolved (exit 127).
RUN npm install -g opencode-ai@1.17.8

# Pre-bake nvm so harbor's opencode agent + the prod opus-proxy `. ~/.nvm/nvm.sh` don't abort on the nvm-less node:24 base.
RUN export NVM_DIR=/root/.nvm \
 && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh | METHOD=script bash \
 && . "$NVM_DIR/nvm.sh" \
 && nvm install 22

WORKDIR /app

# Task repo: drop its contents under environment/repo/ (the Docker build
# context is this environment/ dir). It is copied to /app and its history is
# flattened to a single commit so the agent never sees upstream git history and
# the oracle's `git apply` has a clean tree to patch. Do NOT copy anything from
# tests/ or solution/ into the image.
COPY repo/ /app/
# Flatten the history, then delete what the repo's own .gitignore calls junk:
# __pycache__, caches, build output. That residue is where a leaked answer
# hides — bytecode compiled from the FIXED source, a cache naming the hidden
# tests. Cleaning AFTER the commit is what makes this work at all: most vendored
# repos ship no .git (5 of 9 sampled), but they all ship a .gitignore, and the
# fresh `add -A` honours it. -X (not -x) deletes only ignored files, so anything
# the author added by hand is already committed and safe.
RUN rm -rf /app/.git \
 && git init -q \
 && git add -A \
 && git -c user.email=dev@localhost -c user.name=dev \
        commit -qm "initial commit" \
 && git clean -Xfd
# === END realm base ===

# === optional language toolchains — uncomment what your task needs ===
# Python is already installed above; Node.js ships in the base image.

# --- C / C++ (GCC toolchain) ---
# RUN apt-get update \
#  && apt-get install -y --no-install-recommends \
#         build-essential gcc g++ make pkg-config \
#  && rm -rf /var/lib/apt/lists/*

# --- Go ---
# COPY --from=golang:1.26-bookworm /usr/local/go /usr/local/go
# ENV PATH=/usr/local/go/bin:${PATH}

# --- Rust ---
# Rust links via the system C toolchain, which the slim base lacks. Without
# build-essential (gcc + libc6-dev) `cargo` fails: `linker cc not found`, then
# missing Scrt1.o/crti.o. Install it before rustup.
# RUN apt-get update \
#  && apt-get install -y --no-install-recommends build-essential \
#  && rm -rf /var/lib/apt/lists/*
# ENV CARGO_HOME=/usr/local/cargo \
#     RUSTUP_HOME=/usr/local/rustup \
#     PATH=/usr/local/cargo/bin:${PATH}
# RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
#       | sh -s -- -y --default-toolchain 1.95.0 --profile minimal

# --- C# / .NET SDK ---
# RUN apt-get update \
#  && apt-get install -y --no-install-recommends libicu72 \
#  && rm -rf /var/lib/apt/lists/*
# ENV DOTNET_ROOT=/usr/local/dotnet \
#     PATH=/usr/local/dotnet:${PATH} \
#     DOTNET_CLI_TELEMETRY_OPTOUT=true \
#     DOTNET_NOLOGO=true
# RUN curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- \
#       --channel 8.0 --install-dir /usr/local/dotnet

# === task dependencies (edit me) ===
# Install repo + verifier deps (no network at verify time), e.g.
# `uv sync --all-extras --all-groups` or `uv pip install --system pytest`.
