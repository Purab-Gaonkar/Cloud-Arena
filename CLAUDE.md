# CLAUDE.md — CloudArena Repository Guide

> **CloudArena** is a 2D arcade fighting game (Tekken-style 1v1 combat) built in **Godot 4.x**, backed by an autoscaling, production-grade cloud infrastructure featuring a Python WebSocket game server, a FastAPI matchmaking and stats REST API, Redis 7 for shared state and queues, NGINX for sticky load balancing, and Terraform for Google Cloud Platform (Cloud Run, Memorystore, VPC) deployment.

---

## 1. Project Overview & Architecture

### System Topology
```
                     ┌──────────────────────────────────┐
                     │   Godot 4 Clients (Game Client)   │
                     └─────────────────┬────────────────┘
                                       │ HTTP / WebSocket
                              ┌────────▼────────┐
                              │     NGINX       │  Load Balancer (Port 8080)
                              │  Reverse Proxy  │  • ip_hash (Sticky WebSocket)
                              └───┬──────────┬──┘  • least_conn (REST API)
                                  │          │
                 ┌────────────────▼─┐      ┌─▼────────────────┐
                 │  Game Server 1   │      │ Matchmaking API 1│
                 │   (WebSocket)    │      │  (FastAPI REST)  │
                 │    Port 8765     │      │    Port 8000     │
                 └────────┬─────────┘      └────────┬─────────┘
                          │                         │
                 ┌────────▼─────────┐      ┌────────▼─────────┐
                 │  Game Server 2   │      │ Matchmaking API 2│
                 │    Port 8765     │      │    Port 8000     │
                 └────────┬─────────┘      └────────┬─────────┘
                          │                         │
                          └───────────┬─────────────┘
                                ┌─────▼─────┐
                                │  Redis 7  │  Shared State, Matchmaking
                                │ Port 6379 │  Queue & Leaderboard
                                └───────────┘
```

### Core Components
| Service / Layer | Technology | Primary Role | Key Files |
|---|---|---|---|
| **Game Client** | Godot 4.x (GDScript) | 2D 1v1 Fighting Game, local & online multiplayer, Tekken HUD | `scenes/`, `scripts/`, `project.godot` |
| **Game Server** | Python 3.11, `websockets`, `aioredis` | Real-time WebSocket game simulation, room management, 60Hz tick loop | `backend/game_server/server.py` |
| **Matchmaking API** | Python FastAPI, Uvicorn, `aioredis` | REST API for room matchmaking, player stats, global leaderboard | `backend/matchmaking_api/main.py` |
| **Load Balancer** | NGINX 1.27 Alpine | Sticky session reverse proxy for WebSockets (`ip_hash`), load balances API (`least_conn`) | `backend/nginx/nginx.conf` |
| **State Store** | Redis 7 (Alpine / Memorystore) | Matchmaking queue (`queue:matchmaking`), room metadata, win leaderboards | `backend/docker-compose.yml` |
| **Infrastructure** | Terraform 1.5+, GCP Cloud Run v2 | Declarative GCP provisioning: Cloud Run, Redis Memorystore, VPC connector, Artifact Registry | `backend/terraform/` |
| **Deployment Script**| Bash / gcloud CLI | Quickstart deployment script for building & pushing Docker images to Cloud Run | `backend/cloud-run/deploy_cloudrun.sh` |

---

## 2. Directory Structure & File Map

```
cloud-arena/
├── CLAUDE.md                      # Claude instructions & repository knowledge base (this file)
├── README.md                      # Project readme
├── project.godot                  # Godot 4 project settings, window size (1280x720), input maps, autoloads
├── export_presets.cfg             # Presets for Windows Desktop & Linux Dedicated Server export
│
├── scenes/                        # Godot 4 Scene Tree (.tscn)
│   ├── main.tscn                  # Starting scene (loads MainMenu)
│   ├── game.tscn                  # Arena battle scene (Camera2D, Floor, Spawner, Players node)
│   └── player.tscn                # Fighter character (CharacterBody2D, Hitbox, Hurtbox, MultiplayerSynchronizer)
│
├── scripts/                       # Active GDScript files
│   ├── main_menu.gd               # Main menu UI, local vs online toggle, HTTP matchmaking call
│   ├── game_manager.gd            # Spawns players, configures parallax/floor, builds Tekken HUD
│   ├── network_manager.gd         # Autoload singleton: WebSocketMultiplayerPeer, keepalive ping loop
│   ├── player_controller.gd       # Fighter state machine (IDLE, MOVE, ATTACK, HIT, KO), netcode input RPC
│   └── tekken_hud.gd              # Tekken arcade HUD: dual health bars, red damage ghost bar, 99s timer
│
├── assets/                        # Graphical game assets & SVGs
│   ├── background.svg             # Parallax background
│   ├── platform.svg               # Arena floor texture
│   ├── player.png                 # Fighter character sprite sheet
│   └── craftpix/                  # Supplementary animation frames
│
├── backend/                       # Cloud Backend & Infrastructure
│   ├── docker-compose.yml         # Local orchestration: Redis + 2x Game Server + 2x API + NGINX
│   │
│   ├── game_server/               # Real-time WebSocket game server
│   │   ├── Dockerfile
│   │   ├── requirements.txt       # websockets, redis
│   │   └── server.py              # WebSocket server, room registry, Redis sync, HTTP health probe (8766)
│   │
│   ├── matchmaking_api/           # REST API
│   │   ├── Dockerfile
│   │   ├── requirements.txt       # fastapi, uvicorn, redis, pydantic
│   │   └── main.py                # Endpoints: /match/join, /match/{id}, /stats/result, /stats/leaderboard
│   │
│   ├── nginx/                     # Reverse proxy & load balancer
│   │   ├── Dockerfile
│   │   └── nginx.conf             # Upstreams: game_servers (ip_hash), matchmaking_api (least_conn)
│   │
│   ├── terraform/                 # GCP Infrastructure as Code
│   │   ├── main.tf                # Cloud Run services, Memorystore Redis, VPC network, Artifact Registry
│   │   ├── variables.tf           # Project ID, region (default us-central1), environment
│   │   ├── outputs.tf             # Service URLs, Redis host IP
│   │   └── terraform.tfvars.example
│   │
│   └── cloud-run/                 # GCP Cloud Run deployment utilities
│       ├── deploy_cloudrun.sh     # Automated build, push, and deploy script
│       ├── game-server.yaml       # Knative service specification
│       └── matchmaking-api.yaml   # Knative service specification
│
├── generate_fighter_sprites.py    # Offline utility: generates procedural fighter sprite frames
├── assets_generator.py            # Offline utility: generates SVG background & platform assets
├── test_server.py                 # Standalone legacy Python test server (reference prototype)
└── [Legacy Root Scripts]          # GameManager.gd, NetworkManager.gd, Player.gd (superseded by scripts/)
```

---

## 3. Game Mechanics & Netcode Details

### Game Modes
1. **Local Mode (Default / 2 Players 1 PC)**:
   - Enabled via main menu "LOCAL PLAY" or when root metadata `local_mode = true`.
   - Both characters are spawned locally under `Players/`.
   - Controls:
     - **Player 1**: `WASD` to move/jump, `J` or `Left Mouse Button` to attack (tap up to 3x for a combo), `S`/`K` to block.
     - **Player 2**: `Arrow Keys` to move/jump, `/` or `Numpad 0` to attack (`p2_attack`), `Down`/`.` to block (`p2_block`).
   - Menu flow: Main menu -> `character_select.tscn` (Brawler / Samurai / Shinobi from `assets/craftpix/`, roster in `scripts/fighter_data.gd`) -> best-of-3 match. "VS CPU" makes P2 an AI. `ESC` pauses.
2. **Online Multiplayer Mode**:
   - Uses Godot's high-level `WebSocketMultiplayerPeer`.
   - Autoload singleton `NetworkManager` (`scripts/network_manager.gd`) manages server/client connections.
   - Authoritative architecture: Peer `1` is the server (dedicated headless instance or hosting player). Remote peers send inputs over RPC:
     ```gdscript
     @rpc("any_peer", "call_local", "reliable")
     func send_input(move_dir: float, jump: bool, attack: bool) -> void
     ```
   - Server simulates physics at 60Hz and replicates state via `MultiplayerSynchronizer`:
     - Synchronized properties: `.:position`, `.:velocity`, `.:health`, `.:current_state`, `.:facing_direction`.
   - **Cloud Run WebSocket Keepalive**: Cloud Run idle timeout defaults to 5 minutes. `NetworkManager` runs an active keepalive loop (`PING_INTERVAL_SEC = 20.0`) sending lightweight ping packets to keep the WebSocket stream open.
   - **Headless Auto-Hosting**: When launched with `--headless` or `dedicated_server` feature flag, `NetworkManager` skips menus and immediately starts hosting on port `7000`.

### Combat & State Machine (`scripts/player_controller.gd`)
- **States**: `IDLE (0)`, `MOVE (1)`, `ATTACK (2)`, `HIT (3)`, `KO (4)`.
- **Combat Stats**:
  - `MOVE_SPEED`: 320.0 px/s
  - `JUMP_VELOCITY`: -520.0 px/s
  - `GRAVITY`: 1000.0 px/s²
  - `ATTACK_DURATION`: 0.38s
  - `HIT_DURATION`: 0.25s
  - `ATTACK_DAMAGE`: 10 HP (Max HP: 100)
- **Collisions**:
  - `CollisionShape2D`: Body physics shape (30x72 px).
  - `Hitbox` (`Area2D`, collision mask 2): Active only during attack frames.
  - `Hurtbox` (`Area2D`, collision layer 2): Always active; takes damage and triggers hit reaction when overlapping an opponent's Hitbox.

### Tekken HUD (`scripts/tekken_hud.gd`)
- Gold-beveled mirrored health bars for P1 (left-to-right) and P2 (right-to-left).
- **Red "Damage Ghost" Lag Bar**: Following a hit, the yellow HP bar drops immediately, while an underlying red ghost bar drains smoothly at 45 HP/s (`move_toward`), replicating authentic arcade fighting games.
- **Center 99-second Countdown Timer**: Flashes red under 10 seconds; triggers "TIME UP!" at 0.
- **Banners**: "ROUND 1", "FIGHT!", "K.O.!", and "TIME UP!" animations.

---

## 4. Backend & API Reference

### Local Docker Compose Endpoints
When running `cd backend && docker compose up --build`:
| Port | Route | Target Service | Description |
|---|---|---|---|
| `8080` | `ws://localhost:8080/ws` | `game_servers` pool | WebSocket game connection (sticky by `ip_hash`) |
| `8080` | `http://localhost:8080/api/match/join` | `matchmaking_api` | Matchmaking join request |
| `8080` | `http://localhost:8080/api/stats/leaderboard` | `matchmaking_api` | Global win leaderboard |
| `8080` | `http://localhost:8080/docs` | `matchmaking_api` | FastAPI Swagger UI |
| `8080` | `http://localhost:8080/nginx-health` | NGINX | Health probe |
| `6379` | `redis://localhost:6379` | Redis | Direct Redis access for debugging |

### Matchmaking REST Endpoints (`backend/matchmaking_api/main.py`)
- `POST /api/match/join`
  - Body: `{"player_name": "Purab", "preferred_room": null}`
  - Response: `{"room_id": "uuid", "ws_url": "ws://...", "player_cnt": 1}`
  - Logic: Pops room ID from Redis list `queue:matchmaking` (O(1)). If none available or expired, creates a new room key `room:{room_id}` in Redis with 10-minute TTL.
- `GET /api/match/{room_id}`
  - Returns current match state and active player count.
- `POST /api/stats/result`
  - Body: `{"room_id": "...", "winner_name": "Purab", "duration_s": 45.2}`
  - Logic: Increments player score in Redis Sorted Set `leaderboard:wins` (`ZINCRBY`) and writes match history into `player:{name}`.
- `GET /api/stats/leaderboard?top=10`
  - Returns top players sorted by wins (`ZREVRANGEBYSCORE`).
- `GET /api/stats/player/{name}`
  - Returns win count and last match timestamp for player.
- `GET /health`
  - Verifies Redis connectivity (`redis.ping()`).

### Game Server (`backend/game_server/server.py`)
- WebSocket protocol on port `8765`.
- Standalone HTTP health server runs concurrently on port `8766` (`GET /health`) for container readiness checks without blocking WebSocket event loops.
- Room lifecycle:
  - Manages player connections, positions, velocity, and attacks.
  - Broadcasts room state ticks to all participants.
  - Publishes available rooms to Redis queue `queue:matchmaking` and cleans up on match completion.

---

## 5. Development & Deployment Commands

### Running Locally with Docker
```bash
# 1. Start all backend services (Redis, 2x Game Servers, 2x Matchmaking APIs, NGINX)
cd backend/
docker compose up --build

# 2. Scale game servers dynamically
docker compose up --scale game-server-1=2

# 3. Clean shutdown (removes volumes)
docker compose down -v
```

### Running the Godot Client
- **Via Godot Editor**: Open `project.godot` in Godot 4.3+, press F5 to run `main.tscn`.
- **Via CLI (Client)**:
  ```bash
  godot --path .
  ```
- **Via CLI (Dedicated Headless Server)**:
  ```bash
  godot --headless --path .
  ```

### Deploying to Google Cloud (GCP)
#### Option A: Terraform (Recommended)
```bash
cd backend/terraform

# Configure credentials and GCP project
gcloud auth login
gcloud auth application-default login
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars -> project_id = "your-gcp-project"

# Deploy
terraform init
terraform plan
terraform apply
```
Outputs from Terraform will provide:
- `game_server_websocket_url`
- `matchmaking_api_url`
- `redis_host`

#### Option B: Automated Bash Script
```bash
cd backend/
chmod +x cloud-run/deploy_cloudrun.sh
./cloud-run/deploy_cloudrun.sh <PROJECT_ID> <REGION> <REDIS_HOST>
```

---

## 6. Code Conventions & Important Rules

### GDScript Guidelines
- Always use static typing where possible (`var speed: float = 320.0`, `func take_damage(amount: int) -> void:`).
- Node references must use `@onready var node_name = $Path` or `get_node_or_null()`.
- Use snake_case for functions and variables (`player_index`, `send_input`), PascalCase for class names and scenes (`CharacterBody2D`, `MainMenu`).
- Signals must be defined at the top of the script using PascalCase or snake_case with clear intent (`signal network_ready`, `signal player_connected(peer_id: int)`).
- Input action names are defined in `project.godot` and must match exactly (`move_left`, `move_right`, `jump`, `attack`, `p2_left`, `p2_right`, `p2_jump`, `p2_attack`).

### Python Backend Guidelines
- Use modern async Python (`asyncio`, `websockets`, `redis.asyncio`).
- Keep health check endpoints non-blocking: game server runs a dedicated background HTTP daemon for port `8766` health probes so heavy WebSocket traffic doesn't fail container health checks.
- Handle Redis connections with pooling via `aioredis.from_url()` and clean teardown in FastAPI's `@asynccontextmanager lifespan`.
- Always structure logs in JSON format for compatibility with GCP Cloud Logging.

### Cloud Run & Networking Gotchas
1. **WebSocket Termination & Session Affinity**: Cloud Run routes requests per-connection. For multiplayer rooms, clients joining the same room must reach the same instance OR rely on an external session affinity router (NGINX `ip_hash` or Cloud Run session affinity).
2. **WebSocket Idle Timeout**: Cloud Run automatically closes WebSocket connections with no data flow after 5 minutes. The 20s keepalive ping in `scripts/network_manager.gd` is essential and must not be removed.
3. **Dedicated Server Mode**: `NetworkManager._is_headless()` checks `DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server")`. Keep this check intact when exporting Linux server binaries.


---

## 7. Local-game architecture notes (menu, world, UI)

- **Boot flow**: `scenes/loading.tscn` (threaded preload of fighter sheets) -> `scenes/main.tscn` (animated menu) -> `scenes/character_select.tscn` (fighters + stage, `TAB` cycles stage) -> `scenes/game.tscn`. All scene changes go through the `Transition` autoload (`scripts/transition.gd`, fade in/out).
- **World art is procedural**: `scripts/world_builder.gd` builds layered parallax stages (3 themes in `STAGES`) from `scripts/scenery.gd` shapes (pagoda, torii, pine, lantern, bamboo, sakura, floor...). Add a stage by adding a dictionary to `STAGES`.
- **UI look**: `scripts/ui_style.gd` holds palette, fonts and styled button/label builders; the HUD uses `scripts/hud_bar.gd` slanted bars.
- **No fighter-vs-fighter body collision**: players use collision layer 4 / mask 1 (floor only); `game_manager._separate_fighters()` nudges overlapping fighters apart so nobody can stand on a head.
- **Match settings live in root metadata** (`local_mode`, `vs_cpu`, `p1_char`, `p2_char`, `stage`).

### Cloud multiplayer readiness (not implemented yet)
- The Online button + matchmaking call and the network spawn path in `game_manager.gd` are preserved untouched.
- Fighter separation and hit resolution run only where `_server_process` runs (local or server), so they stay server-authoritative.
- When online play is built, the chosen `char_id` and `stage` must be carried in the room metadata and replicated (currently network players default to a roster entry by `player_index`, and the stage is random).
- `player_controller.send_input` now takes a 4th `block` argument.
