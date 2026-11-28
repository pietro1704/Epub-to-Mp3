# syntax=docker/dockerfile:1
# check=error=true

# Production image of the Rails web client. The build context is the
# repository root, because the browser runtime is compiled from the Rust
# workspace and nothing generated is committed:
#
#   docker build -t epubtomp3-rails .
#   docker run -p 7860:7860 -e SECRET_KEY_BASE=<secret> epubtomp3-rails
#
# The final image holds Ruby, gems, the application, precompiled assets and
# the generated runtime tree. It has no Node, no Rust toolchain, no
# converter-server and no voice model weights.

# Keep in step with .ruby-version and the tool versions in mise.toml.
ARG RUBY_VERSION=4.0.10
ARG RUST_VERSION=1.99.1
ARG NODE_VERSION=26.13.1

# Stage 1: Rust/WASM bindings. The workspace manifest lists every member, so
# the crates, native and benches trees are all needed to resolve it.
FROM docker.io/library/rust:${RUST_VERSION}-slim AS wasm
WORKDIR /workspace
RUN rustup target add wasm32-unknown-unknown
COPY Cargo.toml Cargo.lock ./
# The CLI must match the wasm-bindgen crate version locked for the workspace.
RUN version="$(awk '/^name = "wasm-bindgen"$/ { found=1; next } found && /^version = / { gsub(/"/, "", $3); print $3; exit }' Cargo.lock)" && \
    test -n "$version" && \
    cargo install wasm-bindgen-cli --version "$version" --locked
COPY crates crates
COPY native native
COPY benches benches
COPY ruby_app/rails_gateway/bin/build-runtime-wasm ruby_app/rails_gateway/bin/build-runtime-wasm
RUN CONVERTER_WASM_BUILD_JOBS="$(nproc)" bash ruby_app/rails_gateway/bin/build-runtime-wasm /runtime/wasm

# Stage 2: pinned browser TTS libraries (ONNX Runtime Web, Piper phonemizer).
FROM docker.io/library/node:${NODE_VERSION}-slim AS tts
WORKDIR /browser_runtime
COPY ruby_app/rails_gateway/browser_runtime/package.json ruby_app/rails_gateway/browser_runtime/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY ruby_app/rails_gateway/browser_runtime/prepare_tts_runtime.mjs ./
RUN node prepare_tts_runtime.mjs /runtime/tts

FROM docker.io/library/ruby:${RUBY_VERSION}-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 sqlite3 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Stage 3: gems, the assembled runtime tree and precompiled assets.
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY ruby_app/rails_gateway/Gemfile ruby_app/rails_gateway/Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY ruby_app/rails_gateway .

# Publish the generated runtime under public/runtime/<id>/ with its manifest.
COPY --from=wasm /runtime/wasm /tmp/runtime/wasm
COPY --from=tts /runtime/tts /tmp/runtime/tts
RUN ruby bin/assemble-runtime --wasm /tmp/runtime/wasm --tts /tmp/runtime/tts --workers browser_runtime/workers && \
    rm -rf /tmp/runtime browser_runtime

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Digest stylesheets and page modules without requiring the real secret.
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Stage 4: the image that runs.
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Thruster is the only listener exposed (0.0.0.0:7860, the Hugging Face Space
# port); it starts Puma on a loopback port and proxies to it.
ENV HTTP_PORT="7860" \
    TARGET_PORT="3000" \
    BINDING="127.0.0.1"
EXPOSE 7860
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS http://127.0.0.1:7860/api/health || exit 1

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
CMD ["./bin/thrust", "./bin/rails", "server"]
