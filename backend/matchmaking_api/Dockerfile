# ── Matchmaking API — Dockerfile ──────────────────────────────────────────────

FROM python:3.12-slim AS builder

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --prefix=/install --no-cache-dir -r requirements.txt


FROM python:3.12-slim AS runtime

RUN groupadd -r cloudapp && useradd -r -g cloudapp cloudapp

WORKDIR /app

COPY --from=builder /install /usr/local
COPY main.py .

EXPOSE 8000

USER cloudapp

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "2", "--log-level", "info"]
