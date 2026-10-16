# CloudArena ⚔️☁️

> A 2D arcade-style fighting game built in **Godot 4**, featuring responsive 1v1 combat, Tekken-style presentation, and an autoscaling cloud backend deployed on **Google Cloud Platform (Cloud Run, Memorystore Redis, NGINX, Terraform)**.

---

## 🎮 Highlights

- **Dual Game Modes**:
  - **Local 2-Player**: Play head-to-head on a single keyboard / mouse (`WASD + J` vs `Arrow Keys + Numpad 0`).
  - **Online Cloud Multiplayer**: Real-time networked combat powered by Godot's `WebSocketMultiplayerPeer` with server-authoritative physics and state replication.
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
- Choose **LOCAL PLAY** to jump into combat immediately, or enter your backend API URL for **MATCHMAKE**.

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