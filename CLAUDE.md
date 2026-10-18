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
│
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


---

## 8. Heavy attacks, finishers, generated art and audio

- **Controls**: heavy = `U` (P1) / `,` or Numpad 1 (P2); super finisher = `I` (P1) / `M` or Numpad 2 (P2). Super needs a full meter (fills from dealing/taking damage; resets each round).
- **States** `HEAVY=6`, `SUPER=7` were appended to the `State` enum in `scripts/player_controller.gd` (keep existing values stable for networking). `meter` is an exported property; add it to the MultiplayerSynchronizer config when online play is built.
- **Super moves** are data in `FighterData.ROSTER[...]["super"]` (dash segments, teleports, timed hits). The super has a 0.45s telegraphed startup (`SUPER_STARTUP`, attacker can be hit and cancelled), then lunges via `begin_super_strike()`; `game_manager.super_cinematic()` (freeze-frame banner) only fires when the first hit actually connects, so the defender can dodge (backdash, jump, block-proof only by evasion). `receive_hit` now returns bool (connected or not).
- **Generated art**: `python tools/gen_sprites.py` (needs `pip install pillow numpy`) rebuilds `assets/generated/` - derived Heavy/Super strips per fighter plus FX sheets (slashes, impact, shockwave, aura, speed lines...). Hand-drawn replacements can use the same file names/frame sizes (`FighterData.FX`). Spawn FX with `FxSprite.spawn()` (`scripts/fx_sprite.gd`).
- **Audio**: `AudioManager` autoload (`scripts/audio_manager.gd`) - music crossfades, pooled SFX, Music/SFX buses, volume sliders saved to `user://settings.cfg`. Logical names map to files in `assets/audio/` (all CC0, see `assets/audio/CREDITS.md`). Missing files are skipped silently.


---

## 9. Controller support, rebinding, depth layers, settings

- **`InputConfig` autoload** (`scripts/input_config.gd`) owns every gameplay binding (keyboard + gamepad) for both players and rebuilds the `InputMap` at startup from defaults + `user://controls.cfg`. P1 gamepad = device 0, P2 = device 1. Default pad layout: stick/D-pad move, A jump, X attack, Y heavy, LB/LT block, B/RB/RT super, Start pause. Rebind UI: `scripts/controls_panel.gd` (Main menu > Controls). Do not edit action events in `project.godot` - they are overwritten at runtime.
- Menu-level actions (`ui_pause`, `ov_*`, `stage_next/prev`) are fixed and registered by `InputConfig`; scenes should poll actions (`Input.is_action_just_pressed`) rather than key codes so pads and rebinding keep working.
- **`GameSettings` autoload** (`scripts/game_settings.gd`): CPU difficulty (EASY/NORMAL/HARD, used by the AI in `player_controller.gd`), screen shake, fullscreen (F11). Audio volumes live in `AudioManager`; both save to `user://settings.cfg`.
- **World depth**: `WorldBuilder` now has ~16 parallax layers (far ridges + haze, light rays, mid trees, hanging lanterns) and two blurred foreground planes in front of the fighters (CanvasGroup + soft-focus shader), plus a vignette. `update_parallax(cam_x, cam_y)` drives them; new sprite kinds live in `scripts/scenery.gd` (vine, hang_lantern, fern, rock, rays).


---

## 10. Dash, training, stats

- **Dash**: double-tap left/right (`_detect_dash` in `player_controller.gd`, local mode only for now). Dashing away from the opponent is a backdash with `BACKDASH_IFRAMES` of invulnerability. `State.DASH=8`.
- **Training mode** (Main menu > TRAINING): P2 is a dummy (`is_dummy`), meter stays full, health refills below 45, no clock/rounds. Driven by root meta `training`.
- **Match stats**: `game_manager.stat_hit/stat_super` collect damage, best combo, supers; shown on the victory screen (`overlay_menu.show_match_end(text, stats)`). Rounds announce `PERFECT!` for flawless wins and `FINAL ROUND` for the decider. The pause screen lists the move set.


---

## 11. Rules, polish and testing notes

- **Throw**: ATTACK + BLOCK pressed together up close (`_try_throw`), unblockable 14 dmg launcher; the CPU throws blockers. **Combo damage scaling** (-10% per extra hit, floor 50%) and **wake-up invulnerability** (0.35s after a heavy knockdown) are in `receive_hit` / `_state_hit`.
- **Match rules** live in `GameSettings` (rounds to win 1-3, round time 99/60/30/none, CPU difficulty, shake, fullscreen, foreground blur); `game_manager.rounds_to_win` and `tekken_hud.configure_rules()` consume them.
- **Stages**: 4 (`FROZEN SHRINE` added, with snow). Each stage has an `actor_tint` that colours fighters to sit in the scene; fighters also get a faint floor reflection (`_refl` in `player_controller.gd`).
- **Audio extras**: footsteps on run frames, music pitch rises slightly when a fighter is nearly KO'd. Credits modal on the main menu (bottom-right).
- **Headless scene switches** from `_ready` must use `change_scene_to_file.call_deferred(...)` (done in `loading_screen.gd` and `main_menu.gd` for dedicated-server mode).
- **Testing recipe** (no test framework): write a throwaway `extends SceneTree` script, set root metas (`local_mode`, `vs_cpu`, `p1_char`, `p2_char`, `stage`, `training`), `change_scene_to_file("res://scenes/game.tscn")`, then drive the game and print state; run with `godot --headless --path . --script file.gd`. For screenshots drop `--headless` and save `root.get_texture().get_image()`. A CPU-vs-CPU soak (`is_cpu = true` on both) and random-input fuzz both complete a full match without script errors.
- **Palettes**: `FighterData.palette_material(i)` hue-shifts a sprite (4 palettes); players pick with `heavy` on the select screen (`p1_pal`/`p2_pal` metas). Mirror matches auto-recolour P2.
- **Training dummy**: `dummy_cycle` action (Tab / R3) switches STAND / BLOCK / FIGHT BACK; the HUD shows last hit, combo count and combo damage.

- **Parry / counter / popups**: blocking within `PARRY_WINDOW` (0.14s) of impact negates the hit, staggers the attacker and gives meter. Hitting an opponent during their attack startup is a COUNTER (+25%). `game_manager.popup_text()` shows damage numbers, PARRY!, COUNTER! and super names in the arena.


---

## 12. Online multiplayer (implemented)

- **Architecture**: headless Godot dedicated servers (one match per process) managed by the Python room manager (`backend/game_server/server.py`); the matchmaking API (`backend/matchmaking_api/main.py`) reserves slots / asks hosts to create rooms. See `backend/README.md`. The old shooter-style Python game server is gone.
- **Client flow**: Main menu ONLINE (API url + name) -> character select (online mode, fighter + palette only) -> `NetworkManager.matchmake()` -> `join_game(ws_url)` -> `game.tscn`. `game_manager` (`_online`, `_is_dedicated`) registers the fighter with `Net.register`, waits for `net_start`, then just renders replicated state.
- **Server flow**: `scripts/online_match.gd` (child node `Net` of the game scene, same RPC set on every peer) accepts 2 peers, builds the match (`gm.online_build_match`), then the normal round flow runs on the server. HUD calls go through `hud_proxy.gd` (applied locally + forwarded with `net_hud`); cosmetic effects are forwarded with `net_call`; gameplay sounds via `AudioManager.net_forward` -> `net_sfx`. Time is never slowed online (no `Engine.time_scale`).
- **Replication** (`scenes/player.tscn`): position, velocity, health, state, facing, meter, combo step, super phase, attack duration, dash flag; spawn-only: char, palette, index, tint, local_mode. Clients only send inputs (`send_input` incl. dash). Fighter authority is set in `_enter_tree` (required by MultiplayerSynchronizer).
- **Lifecycle**: server prints `@@ROOM {json}` lines (ready, player_joined, match_started, match_over, closed), exits when all players leave / nobody joined in time, forfeits to the remaining player on disconnect, rematch needs both players. Results POST to `/stats/result`.
- **Testing**: `python backend/dev_stack.py` (no Docker/Redis) + headless bots (`--client --matchmake=URL --bot`); direct: `godot --headless --path . -- --server --port=7031 --room=x --rounds=1 --time=12` and bots with `--join=ws://127.0.0.1:7031`.
- **Not done / limits**: no client-side prediction (input delay = RTT), reconnect only within the 30 s grace period (section 14), Terraform/Docker files are untested here, stage and arena are server-chosen.


---

## 13. Main menu (dark, text-only)

- `scripts/main_menu.gd` is a small page system: **root** (Play / Settings / Quit) -> **play** (Versus CPU, Two Players, Training, Online) and **settings** (Audio, Video, Gameplay, Controls, Credits); online and leaderboard are sub-pages of Play. Pages cross-fade (`_push` / `_back`, Esc / B steps back); the title shrinks on deep pages (`COMPACT_PAGES`). Add a page by writing `_page_xxx()` and registering it in `_build_page`.
- `scripts/hk_menu_list.gd` is the text-only list control (plain, value and slider rows; focus = brighter text + faint glow + thin underline + side crests; keyboard, pad via `ui_*` actions, and mouse). `scripts/menu_atmosphere.gd` is the backdrop (gradient, ridges with mouse parallax, vines, fog banks, dust motes, vignette). Serif fonts and `minimal_button` live in `ui_style.gd`.
- The only text outside the pages is the game title; no version/sub-header/branding strings. The controls rebinding panel was re-skinned to the same minimal style.


---

## 14. Accounts (online play)

- Online requires an account. `Account` autoload (`scripts/account.gd`) stores username + session token in `user://account.cfg` (never the password); the Online menu page shows Server/Name/Password + Sign In/Create Account, or Find Match/Leaderboard/Sign Out when signed in.
- API: `/auth/register|login|logout|me`, `/match/join` (Bearer token -> room, ws_url, one-time `ticket`), `/auth/ticket/redeem` and `/stats/result` (need `X-Server-Key` = `SERVER_KEY`). scrypt password hashes, hashed session tokens in Redis, rate limits.
- The client sends the ticket in `online_match.register`; the dedicated server redeems it to get the verified username (no ticket = kicked, `auth_rejected`). One account cannot fill both slots.
- Bots: `--user=NAME --pass=PW` (account is created on first use). `SERVER_KEY` is wired into docker-compose (`backend/.env`) and Terraform. Limits: needs HTTPS and durable Redis in production; no password reset/email verification.
- **Firestore (optional)**: with `FIRESTORE_PROJECT_ID` set, the API mirrors accounts (`players/`) and writes match history (`matches/`) in background tasks (sign-up, post-match); login restores an account into Redis if it is missing. Never touched mid-match. Redis can be configured via `REDIS_HOST`/`REDIS_PORT`. Firestore code is untested here (needs credentials or the emulator).

- **Reconnect grace (30 s)**: when a client drops mid-match, `online_match.gd` keeps its slot (`held`, regs/order untouched), freezes the whole simulation with `get_tree().paused` (`gm.online_freeze`; `Net` and `NetworkManager` run `PROCESS_MODE_ALWAYS`; `NetworkManager.hold_active` stops the server quitting), and counts down "OPPONENT DISCONNECTED n" on the other client (`net_status`). The dropped client (`game_manager._reconnect_loop`) frees its fighter nodes, calls `POST /match/rejoin` (Bearer; needs room status `playing` and the account in `room:<id>:users`; returns a fresh ticket) via `NetworkManager.try_rejoin()`, reconnects through the relay, re-registers, and the server re-binds the new peer id to the slot (`_rebind` -> `net_resume`), then unfreezes. After 30 s `_expire_slot` forfeits to the player who stayed. Fighters are named `P0`/`P1` (not peer ids); `owning_peer_id` is set by the server and, on clients, from `info["peers"]`.
- Tested on the dev stack: bot flag `--drop-at=SECONDS` (`NetworkManager.simulate_drop()`) drops and reconnects mid-match (`@@BOT resumed`, match finishes normally); killing a bot process forfeits to the other player after ~30 s. Not tested: both players dropping at once, drops during the round intro, real network loss (relay-level).
