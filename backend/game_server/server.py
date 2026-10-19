"""
CloudArena Room Manager
=======================
Runs on every game-server host (VM / container). For each match it spawns one headless Godot
dedicated-server process, tracks it through the "@@ROOM {json}" lines it prints, publishes the
room in Redis for the matchmaking API, and relays WebSocket traffic from the public port to the
Godot process:

    client ──ws://host:PORT/ws/<room_id>──▶ [this manager] ──ws://127.0.0.1:<godot port>──▶ Godot

Redis keys
    servers                      SET   ids of live managers
    server:<id>:health           STR   heartbeat (TTL 30 s)
    server:<id>:info             HASH  load, capacity, public_ws
    queue:create:<id>            LIST  room ids the matchmaking API wants this manager to create
    room:<room_id>               HASH  status, server_id, ws_url, player_cnt, reserved ...
    queue:matchmaking            LIST  rooms that still have a free slot

Environment variables
    REDIS_URL         redis://localhost:6379   ("memory://" = in-process fake, dev only)
    PORT              public relay + /health port                  (default 8765)
    PUBLIC_WS_BASE    what clients should use as ws base           (default ws://localhost:PORT)
    SERVER_ID         unique id of this manager                    (default random)
    GODOT_BIN         path of the Godot executable                 (default "godot")
    GODOT_PROJECT     project dir or exported .pck for headless    (default ".")
    API_URL           matchmaking API URL handed to Godot servers  (default http://localhost:8000)
    PORT_MIN/PORT_MAX internal ports for Godot processes           (default 7100-7199)
    MAX_ROOMS         max concurrent matches on this host          (default 20)
    ROUNDS            rounds to win                                (default 2)
    ROUND_TIME        seconds per round                            (default 99)
"""

import asyncio
import json
import logging
import os
import re
import signal
import sys
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from typing import Optional

import redis.asyncio as aioredis
from websockets.asyncio.client import connect as ws_connect
from websockets.asyncio.server import serve as ws_serve

# ── Configuration ────────────────────────────────────────────────────────────
DEBUG_LATENCY_MS = float(os.getenv("DEBUG_LATENCY_MS", "0"))   # test only: artificial one-way delay in the relay
REDIS_URL      = os.getenv("REDIS_URL") or f"redis://{os.getenv('REDIS_HOST', 'localhost')}:{os.getenv('REDIS_PORT', '6379')}"
PORT           = int(os.getenv("PORT", "8765"))
SERVER_ID      = os.getenv("SERVER_ID", uuid.uuid4().hex[:8])
PUBLIC_WS_BASE = os.getenv("PUBLIC_WS_BASE", f"ws://localhost:{PORT}").rstrip("/")
GODOT_BIN      = os.getenv("GODOT_BIN", "godot")
GODOT_PROJECT  = os.getenv("GODOT_PROJECT", ".")
API_URL        = os.getenv("API_URL", "http://localhost:8000")
PORT_MIN       = int(os.getenv("PORT_MIN", "7100"))
PORT_MAX       = int(os.getenv("PORT_MAX", "7199"))
MAX_ROOMS      = int(os.getenv("MAX_ROOMS", "20"))
ROUNDS         = os.getenv("ROUNDS", "2")
ROUND_TIME     = os.getenv("ROUND_TIME", "99")
START_TIMEOUT  = float(os.getenv("START_TIMEOUT", "25"))

ROOM_PATH = re.compile(r"/ws/([A-Za-z0-9_-]+)/?$")


logging.basicConfig(level=logging.WARNING)


def log(level: str, msg: str, **kw) -> None:
    print(json.dumps({"ts": datetime.now(timezone.utc).isoformat(), "server_id": SERVER_ID,
                      "level": level, "msg": msg, **kw}), flush=True)


def make_redis(url: str):
    if url.startswith("memory://"):
        import devredis  # provided by backend/dev_stack.py (single-process dev stack)
        return devredis.client()
    return aioredis.from_url(url, decode_responses=True)


class Room:
    stale_since: Optional[float] = None   # when reserved slots first exceeded connected players

    def __init__(self, room_id: str, port: int):
        self.room_id = room_id
        self.port = port
        self.proc: Optional[asyncio.subprocess.Process] = None
        self.status = "starting"
        self.players = 0
        self.ready = asyncio.Event()


class Manager:
    def __init__(self) -> None:
        self.redis = make_redis(REDIS_URL)
        self.rooms: dict[str, Room] = {}
        self.used_ports: set[int] = set()
        self.stop = asyncio.Event()

    # ── Redis helpers ────────────────────────────────────────────────────────
    async def publish_room(self, room: Room, **extra) -> None:
        fields = {"room_id": room.room_id, "server_id": SERVER_ID, "status": room.status,
                  "player_cnt": room.players, "ws_url": f"{PUBLIC_WS_BASE}/ws/{room.room_id}",
                  "updated_at": datetime.now(timezone.utc).isoformat(), **extra}
        await self.redis.hset(f"room:{room.room_id}", mapping=fields)
        await self.redis.expire(f"room:{room.room_id}", 3600)

    async def heartbeat(self) -> None:
        while not self.stop.is_set():
            try:
                await self.redis.sadd("servers", SERVER_ID)
                await self.redis.setex(f"server:{SERVER_ID}:health", 30, "ok")
                await self.redis.hset(f"server:{SERVER_ID}:info", mapping={
                    "load": len(self.rooms), "capacity": MAX_ROOMS, "public_ws": PUBLIC_WS_BASE})
            except Exception as exc:
                log("warn", "heartbeat_failed", error=str(exc))
            await asyncio.sleep(10)

    async def reconcile(self) -> None:
        """Give back slots that were reserved (a ticket was issued) but never used.

        Without this a room could wait forever for a player who crashed between /match/join and connecting.
        """
        loop = asyncio.get_running_loop()
        while not self.stop.is_set():
            await asyncio.sleep(5)
            for room in list(self.rooms.values()):
                if room.status not in ("ready", "waiting"):
                    room.stale_since = None
                    continue
                try:
                    reserved = int(await self.redis.hget(f"room:{room.room_id}", "reserved") or 0)
                    if reserved <= room.players:
                        room.stale_since = None
                        continue
                    if room.stale_since is None:
                        room.stale_since = loop.time()
                    elif loop.time() - room.stale_since > 25:
                        await self.redis.hset(f"room:{room.room_id}", "reserved", room.players)
                        await self.redis.lrem("queue:matchmaking", 0, room.room_id)
                        await self._enqueue(room.room_id)
                        room.stale_since = None
                        log("info", "reservations_released", room=room.room_id, players=room.players)
                except Exception as exc:
                    log("warn", "reconcile_failed", error=str(exc))

    async def _enqueue(self, room_id: str) -> None:
        """Offer a room to public matchmaking, unless it is a private (friend) room."""
        if await self.redis.hget(f"room:{room_id}", "private") == "1":
            return
        await self.redis.lpush("queue:matchmaking", room_id)

    async def create_requests(self) -> None:
        """Rooms the matchmaking API asked this host to start."""
        key = f"queue:create:{SERVER_ID}"
        while not self.stop.is_set():
            try:
                room_id = await self.redis.rpop(key)
            except Exception as exc:
                log("warn", "create_poll_failed", error=str(exc))
                room_id = None
            if room_id:
                asyncio.create_task(self.create_room(room_id))
            else:
                await asyncio.sleep(0.2)

    # ── Room lifecycle ───────────────────────────────────────────────────────
    def _free_port(self) -> Optional[int]:
        for p in range(PORT_MIN, PORT_MAX + 1):
            if p not in self.used_ports:
                return p
        return None

    async def create_room(self, room_id: str) -> None:
        port = self._free_port()
        if port is None or len(self.rooms) >= MAX_ROOMS:
            await self.redis.hset(f"room:{room_id}", mapping={"status": "failed", "error": "server_full"})
            log("warn", "room_rejected_full", room=room_id)
            return
        for var in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            if os.environ.get(var):
                os.makedirs(os.environ[var], exist_ok=True)      # Godot needs its user dirs to exist
        self.used_ports.add(port)
        room = Room(room_id, port)
        self.rooms[room_id] = room
        args = [GODOT_BIN, "--headless", "--path", GODOT_PROJECT, "--", "--server",
                f"--port={port}", f"--room={room_id}", f"--api={API_URL}",
                f"--rounds={ROUNDS}", f"--time={ROUND_TIME}"]
        try:
            room.proc = await asyncio.create_subprocess_exec(
                *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        except Exception as exc:
            log("error", "spawn_failed", room=room_id, error=str(exc))
            await self.redis.hset(f"room:{room_id}", mapping={"status": "failed", "error": "spawn_failed"})
            await self._cleanup(room)
            return
        log("info", "room_starting", room=room_id, port=port, pid=room.proc.pid)
        asyncio.create_task(self._read_output(room))
        asyncio.create_task(self._watch(room))
        try:
            await asyncio.wait_for(room.ready.wait(), START_TIMEOUT)
        except asyncio.TimeoutError:
            log("error", "room_start_timeout", room=room_id)
            await self.redis.hset(f"room:{room_id}", mapping={"status": "failed", "error": "start_timeout"})
            await self._kill(room)

    async def _read_output(self, room: Room) -> None:
        assert room.proc and room.proc.stdout
        async for raw in room.proc.stdout:
            line = raw.decode("utf-8", "replace").rstrip()
            if line.startswith("@@ROOM "):
                try:
                    await self._on_event(room, json.loads(line[7:]))
                except Exception as exc:
                    log("warn", "bad_room_event", room=room.room_id, error=str(exc), line=line)
            elif "ERROR" in line or "SCRIPT ERROR" in line:
                log("warn", "godot_error", room=room.room_id, line=line[:300])

    async def _on_event(self, room: Room, ev: dict) -> None:
        name = ev.get("event")
        if name == "ready":
            room.status = "ready"
            room.ready.set()
            # reserved=1 is set by the matchmaking API for the creating player when it asked for the room.
            await self.publish_room(room)
            reserved = int(await self.redis.hget(f"room:{room.room_id}", "reserved") or 0)
            if reserved < 2:
                await self._enqueue(room.room_id)
        elif name == "player_joined":
            room.players = int(ev.get("count", room.players))
            room.status = "waiting" if room.players < 2 else "full"
            await self.publish_room(room)
            if room.players >= 2:
                await self.redis.lrem("queue:matchmaking", 0, room.room_id)
        elif name == "match_started":
            room.status = "playing"
            await self.publish_room(room)
            await self.redis.lrem("queue:matchmaking", 0, room.room_id)
        elif name == "match_over":
            room.status = "finished"
            await self.publish_room(room, winner=str(ev.get("winner", "")))
        elif name == "player_left":
            if room.status in ("waiting", "ready"):
                room.players = max(0, room.players - 1)
        elif name == "closed":
            log("info", "room_closed", room=room.room_id, reason=ev.get("reason"))

    async def _watch(self, room: Room) -> None:
        assert room.proc
        code = await room.proc.wait()
        log("info", "room_exited", room=room.room_id, code=code)
        await self._cleanup(room)

    async def _kill(self, room: Room) -> None:
        if room.proc and room.proc.returncode is None:
            room.proc.kill()

    async def _cleanup(self, room: Room) -> None:
        self.rooms.pop(room.room_id, None)
        self.used_ports.discard(room.port)
        try:
            await self.redis.lrem("queue:matchmaking", 0, room.room_id)
            await self.redis.delete(f"room:{room.room_id}")
        except Exception as exc:
            log("warn", "cleanup_failed", error=str(exc))

    # ── Public WebSocket relay + HTTP health ─────────────────────────────────
    async def http_handler(self, connection, request):
        path = request.path.split("?")[0]
        if path.endswith("/health"):
            return connection.respond(HTTPStatus.OK, json.dumps({
                "status": "ok", "server_id": SERVER_ID, "rooms": len(self.rooms),
                "capacity": MAX_ROOMS, "players": sum(r.players for r in self.rooms.values())}) + "\n")
        if path.endswith("/rooms"):
            return connection.respond(HTTPStatus.OK, json.dumps([
                {"room_id": r.room_id, "status": r.status, "players": r.players} for r in self.rooms.values()]) + "\n")
        if ROOM_PATH.search(path) is None:
            return connection.respond(HTTPStatus.NOT_FOUND, "not found\n")
        return None  # proceed with the WebSocket handshake

    async def relay(self, ws) -> None:
        m = ROOM_PATH.search(ws.request.path.split("?")[0])
        room = self.rooms.get(m.group(1)) if m else None
        if room is None or not room.ready.is_set():
            await ws.close(4404, "room not found")
            return
        try:
            async with ws_connect(f"ws://127.0.0.1:{room.port}", compression=None,
                                  open_timeout=5, max_size=None, ping_interval=None) as up:
                async def pump(src, dst):
                    if DEBUG_LATENCY_MS <= 0:
                        async for msg in src:
                            await dst.send(msg)
                        return
                    # Debug only: delay every message by DEBUG_LATENCY_MS while keeping order and throughput.
                    queue: asyncio.Queue = asyncio.Queue()
                    loop = asyncio.get_running_loop()

                    async def feed():
                        async for msg in src:
                            queue.put_nowait((loop.time() + DEBUG_LATENCY_MS / 1000.0, msg))
                        queue.put_nowait((0.0, None))
                    feeder = asyncio.create_task(feed())
                    try:
                        while True:
                            due, msg = await queue.get()
                            if msg is None:
                                break
                            wait = due - loop.time()
                            if wait > 0:
                                await asyncio.sleep(wait)
                            await dst.send(msg)
                    finally:
                        feeder.cancel()
                t1 = asyncio.create_task(pump(ws, up))
                t2 = asyncio.create_task(pump(up, ws))
                done, pending = await asyncio.wait({t1, t2}, return_when=asyncio.FIRST_COMPLETED)
                for t in pending:
                    t.cancel()
                for t in done:
                    t.exception()          # an abrupt close is normal (players drop); mark it retrieved
        except Exception as exc:
            log("warn", "relay_failed", room=room.room_id, error=str(exc))
        finally:
            try:
                await ws.close()
            except Exception:
                pass

    # ── Main ─────────────────────────────────────────────────────────────────
    async def run(self) -> None:
        log("info", "manager_starting", port=PORT, public=PUBLIC_WS_BASE, godot=GODOT_BIN, project=GODOT_PROJECT)
        try:
            await self.redis.ping()
        except Exception as exc:
            log("error", "redis_unavailable", error=str(exc))
            raise
        tasks = [asyncio.create_task(self.heartbeat()), asyncio.create_task(self.create_requests()), asyncio.create_task(self.reconcile())]
        async with ws_serve(self.relay, "0.0.0.0", PORT, process_request=self.http_handler,
                            compression=None, max_size=None, ping_interval=None):
            log("info", "manager_ready", port=PORT)
            await self.stop.wait()
        for t in tasks:
            t.cancel()
        for room in list(self.rooms.values()):
            await self._kill(room)
        await self.redis.srem("servers", SERVER_ID)
        log("info", "manager_stopped")


async def main() -> None:
    mgr = Manager()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, mgr.stop.set)
        except NotImplementedError:
            pass  # Windows
    await mgr.run()


if __name__ == "__main__":
    asyncio.run(main())
