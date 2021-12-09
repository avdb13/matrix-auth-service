# Builds a minimal image with the binary only. It is multi-arch capable,
# cross-building to aarch64 and x86_64. When cross-compiling, Docker sets two
# implicit BUILDARG: BUILDPLATFORM being the host platform and TARGETPLATFORM
# being the platform being built.
#
# Docker platform definitions look like this: linux/arm64 and linux/amd64, so
# there is a small script that translates those platforms to LLVM triples,
# respectively x86-64-unknown-linux-gnu and aarch64-unknown-linux-gnu

# The Debian version and version name must be in sync
ARG DEBIAN_VERSION=11
ARG DEBIAN_VERSION_NAME=bullseye
ARG RUSTC_VERSION=1.57.0
ARG NODEJS_VERSION=16

## Build stage that builds the static files/frontend ##
FROM --platform=${BUILDPLATFORM} docker.io/library/node:${NODEJS_VERSION}-${DEBIAN_VERSION_NAME}-slim AS static-files

WORKDIR /app/crates/static-files
COPY ./crates/static-files/package.json ./crates/static-files/package-lock.json /app/crates/static-files/
RUN npm ci
COPY . /app/
RUN npm run build
# Change the timestamp of built files for better caching
RUN find public -type f -exec touch -t 197001010000.00 {} +

## Base image with cargo-chef and the right cross-compilation toolchain ##
# cargo-chef helps with caching dependencies between builds
# The image Debian base name (bullseye) must be in sync with the runtime variant (debian11)
FROM --platform=${BUILDPLATFORM} docker.io/library/rust:${RUSTC_VERSION}-slim-${DEBIAN_VERSION_NAME} AS chef

# Install x86_64 and aarch64 cross-compiling stack
RUN apt update && apt install -y --no-install-recommends \
  g++-x86-64-linux-gnu \
  g++-aarch64-linux-gnu \
  libc6-dev-arm64-cross \
  libc6-dev-amd64-cross \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN cargo install --locked cargo-chef

ENV \
  CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
  CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
  CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++ \
  CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc \
  CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc \
  CXX_x86_64_unknown_linux_gnu=x86_64-linux-gnu-g++

ARG RUSTC_VERSION
ARG TARGETPLATFORM

# Helper script that transforms docker platforms to LLVM triples
COPY ./misc/docker-arch-to-rust-target.sh /
# Install the right toolchain for cross-compilation
RUN rustup target add `/docker-arch-to-rust-target.sh "${TARGETPLATFORM}"` --toolchain "${RUSTC_VERSION}"

## Run the planner from cargo-chef ##
FROM --platform=${BUILDPLATFORM} chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

## Actual build stage ##
FROM --platform=${BUILDPLATFORM} chef AS builder 

ARG TARGETPLATFORM

# Build dependencies
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook \
  --release \
  --recipe-path recipe.json \
  --target $(/docker-arch-to-rust-target.sh "${TARGETPLATFORM}")

# Build the rest
COPY . .
COPY --from=static-files /app/crates/static-files/public /app/crates/static-files/public
RUN cargo build \
  --release \
  --bin mas-cli \
  --target $(/docker-arch-to-rust-target.sh "${TARGETPLATFORM}")

# Move the binary to avoid having to guess its name in the next stage
RUN mv target/$(/docker-arch-to-rust-target.sh "${TARGETPLATFORM}")/release/mas-cli /mas-cli

## Runtime stage, debug variant ##
FROM --platform=${TARGETPLATFORM} gcr.io/distroless/cc-debian${DEBIAN_VERSION}:debug-nonroot AS debug
COPY --from=builder /mas-cli /mas-cli
ENTRYPOINT ["/mas-cli"]

## Runtime stage ##
FROM --platform=${TARGETPLATFORM} gcr.io/distroless/cc-debian${DEBIAN_VERSION}:nonroot
COPY --from=builder /mas-cli /mas-cli
ENTRYPOINT ["/mas-cli"]
