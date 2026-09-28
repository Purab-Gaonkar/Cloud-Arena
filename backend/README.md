# CloudArena — Cloud Backend

> Production-ready cloud backend for the CloudArena Godot fighting game.

## Architecture

```
                ┌─────────────────────────────────┐
                │     Clients (Godot Game)         │
                └──────────────┬──────────────────┘
                               │ HTTP / WebSocket
                       ┌───────▼────────┐
                       │     NGINX      │  ← Load Balancer
                       │  (port 8080)   │    ip_hash sticky WS
                       └──┬────────┬───┘    least_conn API
                          │        │
            ┌─────────────▼──┐  ┌──▼────────────────┐
            │  Game Server 1 │  │  Matchmaking API 1 │
            │  (WebSocket)   │  │  (FastAPI REST)    │
            │  port 8765     │  │  port 8000         │
            └────────┬───────┘  └─────────┬──────────┘
                     │                    │
            ┌────────▼──┐      ┌──────────▼──────────┐
            │Game Server│      │  Matchmaking API 2  │
            │    2      │      │                     │
            └────────┬──┘      └─────────┬───────────┘
                     │                   │
                     └─────────┬─────────┘
                           ┌───▼───┐
                           │ Redis │  ← Shared state
                           └───────┘
```

### Services

| Service | Technology | Role |
|---|---|---|
| **game-server** | Python + websockets | Real-time WebSocket game logic, room management |
| **matchmaking-api** | FastAPI + uvicorn | REST API for matchmaking, stats, leaderboard |
| **nginx** | NGINX 1.27 | Load balancer, WebSocket proxy, sticky sessions |
| **redis** | Redis 7 | Room state sync, player stats, leaderboard |

---

## Local Development (Docker Compose)

### Prerequisites
- Docker Desktop installed and running
- (Windows) WSL2 backend recommended

### Start everything
```bash
cd backend/
docker compose up --build
```

### Endpoints (once running)
| Endpoint | Description |
|---|---|
| `ws://localhost:8080/ws` | WebSocket game server (via NGINX) |
| `http://localhost:8080/api/match/join` | POST — join a match |
| `http://localhost:8080/api/stats/leaderboard` | GET — top players |
| `http://localhost:8080/docs` | FastAPI Swagger UI |
| `http://localhost:8080/nginx-health` | NGINX health check |

### Scale game servers
```bash
# Bring up 4 game-server instances:
docker compose up --scale game-server-1=1 --scale game-server-2=1
# Or just edit nginx/nginx.conf upstream block and re-run
```

### Stop & clean up
```bash
docker compose down -v   # -v removes Redis volume too
```

---

## Deploy to GCP Cloud Run

You have two options for deploying to Google Cloud: using the provided Bash script or using Terraform (Infrastructure as Code).

### Option 1: Terraform (Recommended for Production)

We provide a complete Terraform setup in the [`terraform/`](terraform/) directory that manages the entire GCP infrastructure (Cloud Run, Memorystore Redis, VPC, Artifact Registry). 

See the [Terraform README](terraform/README.md) for full instructions on deploying via Terraform.

### Option 2: Bash Script (Quickstart)

#### One-time setup
```bash
gcloud services enable run.googleapis.com artifactregistry.googleapis.com redis.googleapis.com vpcaccess.googleapis.com
```

#### Create a Memorystore Redis instance
```bash
gcloud redis instances create cloud-arena-redis \
  --size=1 \
  --region=us-central1 \
  --redis-version=redis_7_0

# Get the host IP:
gcloud redis instances describe cloud-arena-redis --region=us-central1 \
  --format="value(host)"
```

#### Deploy
```bash
cd backend/
chmod +x cloud-run/deploy_cloudrun.sh
./cloud-run/deploy_cloudrun.sh  YOUR_PROJECT_ID  us-central1  REDIS_IP
```

### Update Godot client
After deploying, update [`NetworkManager.gd`](../scripts/network_manager.gd):
```gdscript
# Replace the join_game url with your Cloud Run URL (wss://)
var url := "wss://<your-cloud-run-url>/ws"
```

---

## Environment Variables

### game-server
| Variable | Default | Description |
|---|---|---|
| `REDIS_URL` | `redis://localhost:6379` | Redis connection string |
| `PORT` | `8765` | WebSocket listen port |
| `HEALTH_PORT` | `8766` | HTTP health check port |
| `SERVER_ID` | auto UUID | Instance identifier |
| `MAX_ROOMS` | `50` | Max concurrent rooms per instance |
| `MAX_PLAYERS_ROOM` | `4` | Players per room |

### matchmaking-api
| Variable | Default | Description |
|---|---|---|
| `REDIS_URL` | `redis://localhost:6379` | Redis connection string |
| `GAME_SERVER_WS_HOST` | `ws://localhost:8765` | Public WS URL returned to clients |

---

## API Reference

### `POST /api/match/join`
Find an available room or request a new one.
```json
// Request
{ "player_name": "Purab", "preferred_room": null }

// Response
{ "room_id": "a1b2c3d4", "ws_url": "wss://...", "player_cnt": 1 }
```

### `GET /api/match/{room_id}`
Check live match state.

### `POST /api/stats/result`
Record match result.
```json
{ "room_id": "a1b2c3d4", "winner_name": "Purab", "duration_s": 142.5 }
```

### `GET /api/stats/leaderboard?top=10`
Top players by win count.

### `GET /api/stats/player/{name}`
Individual player stats.
