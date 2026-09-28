"""
CloudArena Game Server
======================
Production-ready WebSocket game server with:
  - Room-based match management
  - Redis-backed shared state (allows multiple instances behind an LB)
  - Structured JSON logging
  - Health-check HTTP endpoint (GET /health) on same process
  - Graceful shutdown

Environment Variables:
  REDIS_URL        e.g. redis://redis:6379   (default: redis://localhost:6379)
  PORT             WebSocket server port     (default: 8765)
  HEALTH_PORT      HTTP health port          (default: 8766)
  SERVER_ID        Unique ID for this pod    (default: auto-generated)
  MAX_ROOMS        Max concurrent rooms      (default: 50)
  MAX_PLAYERS_ROOM Max players per room      (default: 4)
"""

import asyncio
import json
import math
import os
import random
import signal
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread
from typing import Optional

import redis.asyncio as aioredis
import websockets
from websockets.server import WebSocketServerProtocol

# ── Configuration ────────────────────────────────────────────────────────────
REDIS_URL        = os.getenv("REDIS_URL",        "redis://localhost:6379")
PORT             = int(os.getenv("PORT",          "8765"))
HEALTH_PORT      = int(os.getenv("HEALTH_PORT",   "8766"))
SERVER_ID        = os.getenv("SERVER_ID",         str(uuid.uuid4())[:8])
MAX_ROOMS        = int(os.getenv("MAX_ROOMS",      "50"))
MAX_PLAYERS_ROOM = int(os.getenv("MAX_PLAYERS_ROOM", "4"))

# ── Logging ───────────────────────────────────────────────────────────────────
def log(level: str, msg: str, **kwargs):
    entry = {
        "ts":        datetime.now(timezone.utc).isoformat(),
        "server_id": SERVER_ID,
        "level":     level,
        "msg":       msg,
        **kwargs,
    }
    print(json.dumps(entry), flush=True)


# ── Redis Client ──────────────────────────────────────────────────────────────
redis_client: Optional[aioredis.Redis] = None

async def get_redis() -> aioredis.Redis:
    global redis_client
    if redis_client is None:
        redis_client = aioredis.from_url(REDIS_URL, decode_responses=True)
    return redis_client


# ── Room Registry (local, per-process) ───────────────────────────────────────
# Each Room holds live WebSocket objects — these can't be in Redis.
# Cross-instance routing is handled by NGINX session affinity (sticky sessions).
rooms: dict[str, "GameRoom"] = {}


class GamePlayer:
    """Represents one connected player inside a room."""

    def __init__(self, player_id: int, name: str, ws: WebSocketServerProtocol, room_id: str):
        self.player_id = player_id
        self.name      = name
        self.ws        = ws
        self.room_id   = room_id
        self.x         = random.randint(100, 1900)
        self.y         = random.randint(100, 1900)
        self.rotation  = 0.0
        self.health    = 100
        self.alive     = True

    async def send(self, data: dict):
        try:
            await self.ws.send(json.dumps(data))
        except Exception as exc:
            log("warn", "send_failed", player_id=self.player_id, error=str(exc))


class GameRoom:
    """A single match room holding up to MAX_PLAYERS_ROOM players."""

    def __init__(self, room_id: str):
        self.room_id          = room_id
        self.players:         dict[int, GamePlayer] = {}
        self.next_player_id   = 1
        self.safe_zone_center = (1000, 1000)
        self.safe_zone_radius = 300.0
        self.game_started     = False
        self._loop_task: Optional[asyncio.Task] = None

    # ── Broadcast ────────────────────────────────────────────────────────────
    async def broadcast(self, data: dict, exclude_id: Optional[int] = None):
        tasks = [
            p.send(data)
            for pid, p in self.players.items()
            if p.alive and pid != exclude_id
        ]
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    # ── Player management ─────────────────────────────────────────────────────
    async def add_player(self, name: str, ws: WebSocketServerProtocol) -> GamePlayer:
        pid    = self.next_player_id
        self.next_player_id += 1
        player = GamePlayer(pid, name, ws, self.room_id)
        self.players[pid] = player

        log("info", "player_joined", room=self.room_id, player_id=pid, name=name,
            total=len(self.players))

        await player.send({
            "type": "join_success",
            "player_id": pid,
            "room_id":   self.room_id,
            "spawn_x":   player.x,
            "spawn_y":   player.y,
            "server_id": SERVER_ID,
        })
        await self.broadcast({"type": "player_joined", "player_id": pid,
                               "player_name": name, "spawn_x": player.x,
                               "spawn_y": player.y})

        # Persist room metadata to Redis
        await self._sync_to_redis()

        # Start game loop when room has 2+ players
        if len(self.players) >= 2 and not self.game_started:
            self.game_started = True
            self._loop_task   = asyncio.create_task(self._game_loop())

        return player

    async def remove_player(self, player: GamePlayer):
        self.players.pop(player.player_id, None)
        log("info", "player_left", room=self.room_id, player_id=player.player_id,
            total=len(self.players))
        await self.broadcast({"type": "player_left", "player_id": player.player_id})
        await self._sync_to_redis()

        if not self.players:
            await self._cleanup()

    # ── Gameplay ──────────────────────────────────────────────────────────────
    async def handle_message(self, player: GamePlayer, data: dict):
        msg_type = data.get("type", "")

        if msg_type == "player_update":
            player.x        = data.get("x", player.x)
            player.y        = data.get("y", player.y)
            player.rotation = data.get("rotation", player.rotation)
            await self.broadcast({
                "type": "player_update",
                "player_id": player.player_id,
                "x":         player.x,
                "y":         player.y,
                "rotation":  player.rotation,
            }, exclude_id=player.player_id)

        elif msg_type == "shoot":
            await self._handle_shoot(player, data)

        elif msg_type == "ping":
            await player.send({"type": "pong", "ts": data.get("ts")})

        else:
            log("debug", "unknown_msg", room=self.room_id, msg_type=msg_type)

    async def _handle_shoot(self, shooter: GamePlayer, data: dict):
        sx, sy   = data.get("x", shooter.x), data.get("y", shooter.y)
        dir_x    = data.get("dir_x", 1.0)
        dir_y    = data.get("dir_y", 0.0)
        mag      = math.sqrt(dir_x**2 + dir_y**2) or 1
        dir_x   /= mag
        dir_y   /= mag

        await self.broadcast({
            "type": "shoot", "player_id": shooter.player_id,
            "x": sx, "y": sy, "dir_x": dir_x, "dir_y": dir_y,
        })

        hit_radius = 20
        max_dist   = 1000

        for pid, target in list(self.players.items()):
            if pid == shooter.player_id or not target.alive:
                continue
            dx  = target.x - sx
            dy  = target.y - sy
            dot = dx * dir_x + dy * dir_y
            if not (0 < dot < max_dist):
                continue
            cx   = sx + dot * dir_x
            cy   = sy + dot * dir_y
            dist = math.sqrt((target.x - cx)**2 + (target.y - cy)**2)
            if dist < hit_radius + 16:
                damage        = 25
                target.health -= damage
                log("info", "hit", room=self.room_id, shooter=shooter.player_id,
                    target=pid, dmg=damage, hp=max(0, target.health))
                if target.health <= 0:
                    target.alive = False
                    log("info", "kill", room=self.room_id,
                        killer=shooter.player_id, victim=pid)
                await target.send({"type": "hit", "player_id": pid,
                                   "damage": damage, "health": max(0, target.health)})
                break

    async def _game_loop(self):
        """Periodic state broadcast and safe-zone shrink."""
        shrink_rate = 0.95
        try:
            while self.players:
                await asyncio.sleep(2)
                self.safe_zone_radius = max(50.0, self.safe_zone_radius * shrink_rate)
                alive = [p for p in self.players.values() if p.alive]

                await self.broadcast({
                    "type":          "game_update",
                    "players_alive": len(alive),
                })
                await self.broadcast({
                    "type":     "safe_zone",
                    "center_x": self.safe_zone_center[0],
                    "center_y": self.safe_zone_center[1],
                    "radius":   self.safe_zone_radius,
                })

                if len(alive) <= 1 and self.game_started:
                    winner = alive[0].name if alive else "Nobody"
                    await self.broadcast({"type": "game_over", "winner": winner})
                    log("info", "game_over", room=self.room_id, winner=winner)
                    await asyncio.sleep(5)
                    self._reset()
        except asyncio.CancelledError:
            pass

    def _reset(self):
        self.safe_zone_radius = 300.0
        for p in self.players.values():
            p.health = 100
            p.alive  = True
            p.x      = random.randint(100, 1900)
            p.y      = random.randint(100, 1900)

    async def _cleanup(self):
        if self._loop_task:
            self._loop_task.cancel()
        rooms.pop(self.room_id, None)
        r = await get_redis()
        await r.delete(f"room:{self.room_id}")
        log("info", "room_closed", room=self.room_id)

    async def _sync_to_redis(self):
        """Publish room metadata (not live WS objects) to Redis.

        Also feeds the `queue:matchmaking` List so the API can discover
        open rooms in O(1) via RPOP instead of scanning all keys.
        """
        try:
            r = await get_redis()
            player_cnt = len(self.players)
            meta = {
                "room_id":    self.room_id,
                "server_id":  SERVER_ID,
                "player_cnt": player_cnt,
                "started":    self.game_started,
                "updated_at": datetime.now(timezone.utc).isoformat(),
            }
            await r.hset(f"room:{self.room_id}", mapping=meta)
            await r.expire(f"room:{self.room_id}", 3600)

            # Push to matchmaking queue when the room has space and hasn't started
            if not self.game_started and player_cnt < MAX_PLAYERS_ROOM:
                await r.lpush("queue:matchmaking", self.room_id)
        except Exception as exc:
            log("warn", "redis_sync_failed", error=str(exc))


# ── Connection Handler ────────────────────────────────────────────────────────
async def handle_client(ws: WebSocketServerProtocol):
    player: Optional[GamePlayer] = None
    room:   Optional[GameRoom]   = None

    try:
        async for raw in ws:
            try:
                data     = json.loads(raw)
                msg_type = data.get("type", "")

                if msg_type == "join":
                    # Find or create a room
                    room_id = data.get("room_id") or _find_available_room()
                    if room_id not in rooms:
                        rooms[room_id] = GameRoom(room_id)
                    room   = rooms[room_id]
                    player = await room.add_player(
                        data.get("player_name", f"Player{room.next_player_id}"), ws
                    )

                elif player and room:
                    await room.handle_message(player, data)

                else:
                    await ws.send(json.dumps({"type": "error",
                                              "msg": "Send join first"}))
            except json.JSONDecodeError:
                log("warn", "invalid_json", server=SERVER_ID)
            except Exception as exc:
                log("error", "msg_error", error=str(exc))

    except websockets.exceptions.ConnectionClosedOK:
        pass
    except websockets.exceptions.ConnectionClosedError as exc:
        log("warn", "conn_closed_error", code=exc.code)
    finally:
        if player and room:
            await room.remove_player(player)


def _find_available_room() -> str:
    for rid, room in rooms.items():
        if len(room.players) < MAX_PLAYERS_ROOM:
            return rid
    new_id = str(uuid.uuid4())[:8]
    return new_id


# ── Health Check HTTP Server ──────────────────────────────────────────────────
class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            body = json.dumps({
                "status":    "ok",
                "server_id": SERVER_ID,
                "rooms":     len(rooms),
                "players":   sum(len(r.players) for r in rooms.values()),
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass  # Suppress default access log


def start_health_server():
    srv = HTTPServer(("0.0.0.0", HEALTH_PORT), HealthHandler)
    Thread(target=srv.serve_forever, daemon=True).start()
    log("info", "health_server_started", port=HEALTH_PORT)


# ── Server Heartbeat ─────────────────────────────────────────────────────────
async def _server_heartbeat(stop_event: asyncio.Event) -> None:
    """Write a SETEX heartbeat key every 15 s so the matchmaking API and other
    instances can detect live pods vs. crashed ones (TTL = 30 s)."""
    key = f"server:{SERVER_ID}:health"
    while not stop_event.is_set():
        try:
            r = await get_redis()
            await r.setex(key, 30, "ok")
        except Exception as exc:
            log("warn", "heartbeat_failed", error=str(exc))
        await asyncio.sleep(15)


# ── Entry Point ───────────────────────────────────────────────────────────────
async def main():
    log("info", "server_starting", port=PORT, redis=REDIS_URL, server_id=SERVER_ID)

    # Verify Redis connectivity
    try:
        r = await get_redis()
        await r.ping()
        log("info", "redis_connected", url=REDIS_URL)
    except Exception as exc:
        log("warn", "redis_unavailable", error=str(exc),
            note="State sharing disabled — single-node mode")

    start_health_server()

    stop_event = asyncio.Event()

    def _handle_signal():
        log("info", "shutdown_signal_received")
        stop_event.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _handle_signal)
        except NotImplementedError:
            pass  # Windows

    async with websockets.serve(handle_client, "0.0.0.0", PORT):
        log("info", "websocket_server_ready", port=PORT)
        # Run the Redis heartbeat alongside the WebSocket server
        heartbeat_task = asyncio.create_task(_server_heartbeat(stop_event))
        await stop_event.wait()
        heartbeat_task.cancel()

    log("info", "server_stopped")


if __name__ == "__main__":
    asyncio.run(main())
