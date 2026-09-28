#!/usr/bin/env bash
# ── CloudArena — GCP Cloud Run Deployment Script ─────────────────────────────
#
# Prerequisites:
#   - gcloud CLI installed and authenticated  (gcloud auth login)
#   - Docker installed
#   - Cloud Run API enabled:  gcloud services enable run.googleapis.com
#   - Artifact Registry API: gcloud services enable artifactregistry.googleapis.com
#   - Memorystore Redis instance created (or use a Cloud Run Job w/ Valkey)
#
# Usage:
#   ./deploy_cloudrun.sh [PROJECT_ID] [REGION] [REDIS_HOST]
#
# Example:
#   ./deploy_cloudrun.sh my-gcp-project us-central1 10.0.0.3

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PROJECT_ID="${1:-$(gcloud config get-value project)}"
REGION="${2:-us-central1}"
REDIS_HOST="${3:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"

ARTIFACT_REPO="cloud-arena"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}"

echo "======================================================"
echo " CloudArena — Cloud Run Deploy"
echo " Project : ${PROJECT_ID}"
echo " Region  : ${REGION}"
echo " Registry: ${REGISTRY}"
echo " Redis   : ${REDIS_HOST}:${REDIS_PORT}"
echo "======================================================"

# ── 1. Create Artifact Registry repo (idempotent) ────────────────────────────
echo "[1/6] Ensuring Artifact Registry repository exists..."
gcloud artifacts repositories describe "${ARTIFACT_REPO}" \
  --location="${REGION}" --project="${PROJECT_ID}" 2>/dev/null || \
gcloud artifacts repositories create "${ARTIFACT_REPO}" \
  --repository-format=docker \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --description="CloudArena container images"

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# ── 2. Build & Push — Game Server ─────────────────────────────────────────────
echo "[2/6] Building & pushing game-server image..."
GAME_IMAGE="${REGISTRY}/game-server:latest"
docker build -t "${GAME_IMAGE}" ./game_server
docker push "${GAME_IMAGE}"

# ── 3. Build & Push — Matchmaking API ────────────────────────────────────────
echo "[3/6] Building & pushing matchmaking-api image..."
API_IMAGE="${REGISTRY}/matchmaking-api:latest"
docker build -t "${API_IMAGE}" ./matchmaking_api
docker push "${API_IMAGE}"

# ── 4. Deploy Game Server to Cloud Run ───────────────────────────────────────
echo "[4/6] Deploying game-server to Cloud Run..."
gcloud run deploy cloud-arena-game-server \
  --image="${GAME_IMAGE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --platform=managed \
  --min-instances=1 \
  --max-instances=10 \
  --concurrency=100 \
  --cpu=1 \
  --memory=512Mi \
  --port=8765 \
  --set-env-vars="REDIS_URL=redis://${REDIS_HOST}:${REDIS_PORT},HEALTH_PORT=8766" \
  --allow-unauthenticated \
  --timeout=3600 \
  --network=default \
  --subnet=default \
  --vpc-egress=private-ranges-only \
  --no-traffic              # Deploy without shifting traffic yet (for canary)

# Promote to 100% traffic
gcloud run services update-traffic cloud-arena-game-server \
  --to-latest \
  --region="${REGION}" \
  --project="${PROJECT_ID}"

GAME_SERVER_URL=$(gcloud run services describe cloud-arena-game-server \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format="value(status.url)")

echo "  ✓ Game server URL: ${GAME_SERVER_URL}"

# ── 5. Deploy Matchmaking API to Cloud Run ───────────────────────────────────
echo "[5/6] Deploying matchmaking-api to Cloud Run..."
gcloud run deploy cloud-arena-matchmaking-api \
  --image="${API_IMAGE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --platform=managed \
  --min-instances=1 \
  --max-instances=5 \
  --concurrency=200 \
  --cpu=1 \
  --memory=256Mi \
  --port=8000 \
  --set-env-vars="REDIS_URL=redis://${REDIS_HOST}:${REDIS_PORT},GAME_SERVER_WS_HOST=${GAME_SERVER_URL}" \
  --allow-unauthenticated \
  --timeout=30 \
  --network=default \
  --subnet=default \
  --vpc-egress=private-ranges-only

gcloud run services update-traffic cloud-arena-matchmaking-api \
  --to-latest \
  --region="${REGION}" \
  --project="${PROJECT_ID}"

API_URL=$(gcloud run services describe cloud-arena-matchmaking-api \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format="value(status.url)")

echo "  ✓ Matchmaking API URL: ${API_URL}"

# ── 6. Summary ────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo " Deployment Complete!"
echo ""
echo "  WebSocket Game Server : ${GAME_SERVER_URL}"
echo "  Matchmaking API       : ${API_URL}"
echo "  Leaderboard           : ${API_URL}/api/stats/leaderboard"
echo "  API Docs (Swagger)    : ${API_URL}/docs"
echo ""
echo "  Update your Godot NetworkManager.gd:"
echo "    DEFAULT_PORT = 443"
echo "    join_game url = ${GAME_SERVER_URL} (wss://)"
echo "======================================================"
