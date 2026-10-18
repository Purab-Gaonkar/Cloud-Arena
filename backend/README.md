# CloudArena backend

Online play is **server-authoritative**: every match runs inside a headless Godot process (the same game
code as the client), so combat rules exist in exactly one place.

```
 Godot client ──HTTP──▶ Matchmaking API (FastAPI) ──Redis──▶ Room manager (game host)
      │                                                         │ spawns 1 process per match
      └──────────WebSocket (wss://host/ws/<room>)──▶ relay ──▶ headless Godot server
```

| Part | Where | Role |
|---|---|---|
| Matchmaking API | `matchmaking_api/main.py` | `POST /match/join` reserves a slot in an open room or asks the least-loaded game host to create one. Records results and serves the leaderboard. |
| Room manager | `game_server/server.py` | Runs on each game host. Spawns/monitors headless Godot servers (`godot --headless -- --server --port=N --room=ID`), reads their `@@ROOM {json}` status lines, publishes rooms to Redis and relays WebSockets from one public port. |
| Godot dedicated server | `scripts/network_manager.gd`, `scripts/online_match.gd`, `scripts/game_manager.gd` | One match per process: accepts 2 clients, runs rounds/combat, reports the winner to the API and exits when everyone has left. |
| Redis | - | Rooms, matchmaking queue, server heartbeats, leaderboard. |
| NGINX | `nginx/nginx.conf` | Local entry point: `/api/*` to the API pool, `/g1/*` and `/g2/*` to game hosts. |

## Run it locally without Docker (fastest)

Needs Python 3.11+ and Godot 4.7:

```bash
pip install websockets redis fakeredis fastapi uvicorn
python backend/dev_stack.py        # API :8000, relay :8765, in-memory Redis
```
Set `GODOT_BIN` if Godot is not at the default Windows path. In the game open **ONLINE**, keep
`http://127.0.0.1:8000`, press **FIND MATCH**, and start a second client (or a bot):

```bash
godot --headless --path . -- --client --matchmake=http://127.0.0.1:8000 --char=Samurai --name=Bot --bot
```

## Run it with Docker Compose

```bash
cd backend && docker compose up --build
```
Game ONLINE menu address: `http://localhost:8080/api`. (Not yet exercised on this machine: Docker was not installed.)

## Deploy to Google Cloud (Terraform)

```bash
cd backend/terraform && cp terraform.tfvars.example terraform.tfvars   # set project_id
terraform init && terraform apply
```
Then build and push `game-server` (from the repo root: `docker build -f backend/game_server/Dockerfile .`) and
`matchmaking-api` images to the Artifact Registry repository printed in the outputs and redeploy the services.
Each **game host** is one Cloud Run instance running up to `rooms_per_host` matches (CPU always allocated, WebSocket
timeout 1 h). Add capacity with `game_host_count`; the API spreads new rooms by load. Players enter the printed
`matchmaking_api_url` in the ONLINE menu. (Terraform was written but not applied from this machine.)

## Dedicated-server command line

`godot --headless --path . -- --server --port=7100 --room=abc --api=http://api:8000 --rounds=2 --time=99`

| Flag | Meaning |
|---|---|
| `--server` | run as dedicated server (also implied by `--headless` without `--join/--client`) |
| `--port`, `--room` | listen port and room id |
| `--api` | where to POST `/stats/result` |
| `--rounds`, `--time` | rounds to win, seconds per round |
| `--idle` | seconds to wait for players before exiting (default 90) |

Test client flags: `--client --join=ws://host:port` or `--client --matchmake=http://api`, plus `--char`, `--name`, `--bot`
(random play), `--rematch`, `--shot=a.png --shot-at=10` (screenshots).

## API summary

`POST /match/join {player_name}` -> `{room_id, ws_url, ...}` · `GET /match/{room_id}` · `GET /rooms` ·
`POST /stats/result {room_id, winner_name, duration_s}` · `GET /stats/leaderboard?top=10` · `GET /stats/player/{name}` · `GET /health`

## Accounts and SERVER_KEY

Online play requires an account (`/auth/register`, `/auth/login`). Passwords are hashed with scrypt; the
client keeps only an opaque session token. `/match/join` needs that token and returns a one-time
join ticket that the game server redeems (`/auth/ticket/redeem`) to learn who connected.

`SERVER_KEY` is a shared secret between the API and game hosts, protecting ticket redemption and
`/stats/result`. Docker: copy `.env.example` to `.env` and set a long random value. Terraform generates one
(`random_password.server_key`). Production notes: serve the API over HTTPS, use a durable Redis (AOF /
Memorystore with persistence) since accounts live there; there is no password reset or email verification yet.

## Firestore (optional permanent store)

Set `FIRESTORE_PROJECT_ID` on the matchmaking API (Terraform does this) and accounts plus match history
are also written to Firestore (`players/`, `matches/`). Writes happen in the background at sign-up and after
a match; if Redis is wiped, a player's account is restored from Firestore on their next login. Firestore is
never touched while a match is running. Unset = Redis only (local dev). Redis may also be configured with
`REDIS_HOST`/`REDIS_PORT` instead of `REDIS_URL`.
