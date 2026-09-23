ARG VARIANT=ubuntu-24.04
FROM mcr.microsoft.com/devcontainers/base:${VARIANT}

ARG FLUTTER_VERSION=stable

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    clang cmake ninja-build g++ pkg-config xz-utils curl unzip ca-certificates git \
    libgtk-3-dev libwebkit2gtk-4.1-dev libsecret-1-dev libdbus-1-dev liblzma-dev libfuse2t64 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

USER vscode

ENV CARGO_HOME=/home/vscode/.cargo
ENV PATH="/home/vscode/.cargo/bin:${PATH}"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal \
    && rustup component add rustfmt clippy

RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /home/vscode/flutter \
    && flutter config --no-analytics \
    && flutter precache --linux

ENV PATH="/home/vscode/flutter/bin:${PATH}"