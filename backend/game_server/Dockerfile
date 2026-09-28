# ── Game Server — Dockerfile ─────────────────────────────────────────────────
# Multi-stage build: compile dependencies in builder, copy to slim runtime image.

# ── Stage 1: Builder ──────────────────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /app

# Install build tools (needed for some native wheels)
RUN apt-get update && apt-get install -y --no-install-recommends gcc && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --prefix=/install --no-cache-dir -r requirements.txt


# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Non-root user for security
RUN groupadd -r cloudapp && useradd -r -g cloudapp cloudapp

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /install /usr/local

# Copy source code
COPY server.py .

# Health probe path
EXPOSE 8765
EXPOSE 8766

USER cloudapp

# Start the server
CMD ["python", "-u", "server.py"]
