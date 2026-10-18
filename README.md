# CloudArena ⚔️☁️

> A 2D arcade-style fighting game built in **Godot 4**, featuring responsive 1v1 combat, Tekken-style presentation, and an autoscaling cloud backend deployed on **Google Cloud Platform (Cloud Run, Memorystore Redis, NGINX, Terraform)**.

---

## 🎮 Highlights

- **Game Modes**:
  - **VS CPU / Local 2-Player / Training**: three fighters (Brawler, Samurai, Shinobi), best-of-3 rounds, three stages.
  - **Online Cloud Multiplayer** *(backend ready, client integration in progress)*: real-time networked combat powered by Godot's `WebSocketMultiplayerPeer` with server-authoritative physics and state replication.
- **Combat**: 3-hit combos, heavy attacks, blocking with chip damage, throws (attack + block), dash / invulnerable backdash, and a super meter with a cinematic finisher per fighter.
- **Presentation**: animated menu and loading screen, layered parallax stages with foreground depth, generated FX sprites, music and SFX (CC0), full controller support and rebindable controls.
- **Tekken-Style Presentation**:
  - Dual mirrored health bars with gold-beveled framing.
  - Smoothly draining **red damage ghost lag bars**.
  - Center 99-second countdown timer with dynamic color alerts.
  - Arcade fight announcements: *"ROUND 1"*, *"FIGHT!"*, *"K.O.!"*, *"TIME UP!"*.
- **Production Cloud Architecture**:
  - **Game Server**: Python `websockets` 60Hz tick simulation with Redis room state.
  - **Matchmaking & Stats API**: Python FastAPI with O(1) Redis queue matchmaking and persistent global win leaderboard.
  - **NGINX Load Balancer**: Sticky sessions (`ip_hash`) for uninterrupted WebSocket gameplay and `least_conn` API routing.
  - **Infrastructure as Code**: Full GCP infrastructure defined in **Terraform** (Cloud Run v2, Memorystore Redis 7, Serverless VPC Access, Artifact Registry).

---

## 🚀 Quick Start

### 1. Run the Game (Godot 4.3+)
- Open this repository folder in **Godot Engine 4.x**.
- Press **F5** to run `scenes/main.tscn`.
- Choose **VS CPU**, **LOCAL 2P** or **TRAINING** to fight immediately, or use **ONLINE** with your backend API URL.

#### Default controls (rebindable in *Controls*; gamepads work out of the box)
| Action | Player 1 | Player 2 | Gamepad |
|---|---|---|---|
| Move / Jump | `A` `D` / `W` | `←` `→` / `↑` | D-pad or stick / `A` |
| Attack (tap x3 = combo) | `J` | `/` or Numpad 0 | `X` |
| Heavy attack | `U` | `,` or Numpad 1 | `Y` |
| Block | `S` / `K` | `↓` / `.` | `LB` / `LT` |
| Throw | Attack + Block | Attack + Block | `X` + `LB` |
| Super finisher (full meter) | `I` | `M` or Numpad 2 | `B` / `RB` |
| Dash / backdash | double-tap `A`/`D` | double-tap `←`/`→` | double-tap D-pad |
| Pause | `Esc` | `Esc` | `Start` |

### 2. Run the Cloud Backend Locally (Docker)
```bash
cd backend/
docker compose up --build
```

Endpoints available on `localhost:8080`:
- **WebSocket Game Server**: `ws://localhost:8080/ws`
- **Matchmaking Join**: `POST http://localhost:8080/api/match/join`
- **Global Leaderboard**: `GET http://localhost:8080/api/stats/leaderboard`
- **Swagger Documentation**: `http://localhost:8080/docs`

### 3. Deploy to Google Cloud (GCP)
```bash
cd backend/terraform
cp terraform.tfvars.example terraform.tfvars
# Set your GCP Project ID in terraform.tfvars
terraform init
terraform apply
```
*See [backend/terraform/README.md](backend/terraform/README.md) and [backend/README.md](backend/README.md) for step-by-step cloud deployment instructions.*

---

## 📂 Repository Structure

- [`scenes/`](scenes/): Godot scenes for Main Menu, Arena (`game.tscn`), and Fighter (`player.tscn`).
- [`scripts/`](scripts/): GDScript controllers for combat physics, networking, and the Tekken HUD.
- [`backend/`](backend/): Docker Compose, FastAPI matchmaking service, WebSocket game server, and NGINX config.
- [`backend/terraform/`](backend/terraform/): Terraform configurations for GCP deployment.
- [`CLAUDE.md`](CLAUDE.md): Detailed architectural guide, networking mechanics, and developer conventions for AI-assisted engineering with Claude.

---

## 📜 Controls (Local Mode)

| Action | Player 1 | Player 2 |
|---|---|---|
| **Move Left / Right** | `A` / `D` | `Left Arrow` / `Right Arrow` |
| **Jump** | `W` or `Space` | `Up Arrow` |
| **Attack** | `J` or `Left Click` | `Numpad 0` or `Right Click` |