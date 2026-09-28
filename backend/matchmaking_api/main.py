"""
CloudArena Matchmaking & Stats API
===================================
FastAPI service providing:
  - POST /match/join       — request a match slot (returns server/room info)
  - GET  /match/{room_id}  — poll match status
  - POST /stats/result     — record match result
  - GET  /stats/leaderboard — top-10 players
  - GET  /health           — health check

Backed by Redis for real-time room state and player stats.

Environment Variables:
  REDIS_URL   (default: redis://localhost:6379)
  API_PORT    (default: 8000)
  GAME_SERVER_WS_HOST  Public WS host for clients (e.g. ws://35.x.x.x)
"""

import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import redis.asyncio as aioredis
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# ── Config ────────────────────────────────────────────────────────────────────
REDIS_URL            = os.getenv("REDIS_URL",            "redis://localhost:6379")
GAME_SERVER_WS_HOST  = os.getenv("GAME_SERVER_WS_HOST",  "ws://localhost:8765")

# ── Redis ─────────────────────────────────────────────────────────────────────
redis_client: aioredis.Redis | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global redis_client
    redis_client = aioredis.from_url(REDIS_URL, decode_responses=True)
    await redis_client.ping()
    yield
    await redis_client.aclose()


# ── App ───────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="CloudArena API",
    description="Matchmaking and player stats for CloudArena",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Schemas ───────────────────────────────────────────────────────────────────
class JoinRequest(BaseModel):
    player_name: str
    preferred_room: str | None = None


class MatchResult(BaseModel):
    room_id:     str
    winner_name: str
    duration_s:  float


# ── Helpers ───────────────────────────────────────────────────────────────────
async def _find_or_create_room(preferred: str | None) -> dict:
    """
    Match a player to an available room using a Redis List queue (O(1)).
    The game-server publishes open room IDs to `queue:matchmaking` via LPUSH.
    We RPOP from that queue, validate the room still has space, and return it.
    Falls back to signalling the game-server to create a new room.
    """
    # Try preferred room first (direct lookup, no queue needed)
    if preferred:
        meta = await redis_client.hgetall(f"room:{preferred}")
        if meta and int(meta.get("player_cnt", 0)) < 4:
            return _room_response(meta, preferred)

    # Pop candidates from the matchmaking queue until we find one with space
    # (rooms may have filled between being enqueued and now)
    for _ in range(10):  # bound iterations to avoid infinite loops
        room_id = await redis_client.rpop("queue:matchmaking")
        if room_id is None:
            break  # queue empty
        meta = await redis_client.hgetall(f"room:{room_id}")
        if not meta:
            continue  # stale entry — room already closed
        if int(meta.get("player_cnt", 0)) < 4:
            # Re-enqueue if still has more space for additional players
            if int(meta.get("player_cnt", 0)) < 3:
                await redis_client.lpush("queue:matchmaking", room_id)
            return _room_response(meta, room_id)

    # No room available — client will auto-create one on game-server connect
    return {
        "room_id":    None,
        "server_id":  None,
        "ws_url":     GAME_SERVER_WS_HOST,
        "player_cnt": 0,
        "note":       "new_room_will_be_created",
    }


def _room_response(meta: dict, room_id: str) -> dict:
    return {
        "room_id":    room_id,
        "server_id":  meta.get("server_id"),
        "ws_url":     GAME_SERVER_WS_HOST,
        "player_cnt": int(meta.get("player_cnt", 0)),
        "started":    meta.get("started") == "True",
    }


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    try:
        await redis_client.ping()
        redis_ok = True
    except Exception:
        redis_ok = False
    return {"status": "ok", "redis": redis_ok}


@app.post("/match/join")
async def join_match(req: JoinRequest):
    """
    Find an available room or indicate a new one will be created.
    Returns the WebSocket URL and room_id the client should use.
    """
    room_info = await _find_or_create_room(req.preferred_room)
    return room_info


@app.get("/match/{room_id}")
async def get_match(room_id: str):
    """Poll the live state of a match from Redis."""
    meta = await redis_client.hgetall(f"room:{room_id}")
    if not meta:
        raise HTTPException(status_code=404, detail="Room not found")
    return {
        "room_id":    room_id,
        "server_id":  meta.get("server_id"),
        "player_cnt": int(meta.get("player_cnt", 0)),
        "started":    meta.get("started") == "True",
        "updated_at": meta.get("updated_at"),
    }


@app.post("/stats/result")
async def record_result(result: MatchResult):
    """Record match result and update winner's score."""
    winner_key = f"player:stats:{result.winner_name}"
    pipe = redis_client.pipeline()
    pipe.hincrby(winner_key, "wins", 1)
    pipe.hincrbyfloat(winner_key, "total_playtime_s", result.duration_s)
    pipe.hsetnx(winner_key, "first_win", datetime.now(timezone.utc).isoformat())
    pipe.zadd("leaderboard", {result.winner_name: 1}, nx=False, incr=True)
    await pipe.execute()
    return {"status": "recorded", "winner": result.winner_name}


@app.get("/stats/leaderboard")
async def leaderboard(top: int = 10):
    """Return the top-N players by win count."""
    entries = await redis_client.zrevrange("leaderboard", 0, top - 1, withscores=True)
    board = []
    for rank, (name, score) in enumerate(entries, start=1):
        stats = await redis_client.hgetall(f"player:stats:{name}")
        board.append({
            "rank":            rank,
            "player_name":     name,
            "wins":            int(score),
            "total_playtime_s": float(stats.get("total_playtime_s", 0)),
            "first_win":       stats.get("first_win"),
        })
    return {"leaderboard": board}


@app.get("/stats/player/{name}")
async def player_stats(name: str):
    """Fetch individual player stats."""
    stats = await redis_client.hgetall(f"player:stats:{name}")
    if not stats:
        raise HTTPException(status_code=404, detail="Player not found")
    rank = await redis_client.zrevrank("leaderboard", name)
    return {
        "player_name":      name,
        "wins":             int(stats.get("wins", 0)),
        "total_playtime_s": float(stats.get("total_playtime_s", 0)),
        "first_win":        stats.get("first_win"),
        "rank":             (rank + 1) if rank is not None else None,
    }
