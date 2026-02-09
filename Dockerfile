FROM ghcr.io/foundry-rs/foundry:latest

# Run as root to avoid permission issues with build artifacts
USER root

WORKDIR /app

# Copy dependency manifests first (cache layer)
COPY foundry.toml remappings.txt ./
COPY lib/ lib/

# Copy source, tests, scripts
COPY src/ src/
COPY test/ test/
COPY script/ script/

# Build contracts
RUN forge build

# Override image's ENTRYPOINT so CMD works as a full command
ENTRYPOINT []
CMD ["forge", "test", "-vvv"]
