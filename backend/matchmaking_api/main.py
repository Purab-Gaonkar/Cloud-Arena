"""
CloudArena Matchmaking & Stats API
===================================
  POST /match/join          - claim a free slot in an open room, or have a game host create a room
  GET  /match/{room_id}     - live status of a room
  GET  /rooms               - rooms currently open for matchmaking (debug)
  POST /stats/result        - record a finished match (called by the Godot dedicated server)
  GET  /stats/leaderboard   - top players by wins
  GET  /stats/player/{name}
  GET  /health

Rooms are created by the room managers (backend/game_server/server.py). This API only decides which
manager should host a new room (least loaded live manager) and reserves player slots.

Environment variables
  REDIS_URL            redis://localhost:6379  ("memory://" = in-process fake, dev only)
  ROOM_CREATE_TIMEOUT  seconds to wait for a new room to boot (default 25)
"""

import asyncio
import hashlib
import hmac
import json
import os
import re
import secrets
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import redis.asyncio as aioredis
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# REDIS_URL wins; otherwise build it from REDIS_HOST / REDIS_PORT (Memorystore style).
REDIS_URL           = os.getenv("REDIS_URL") or f"redis://{os.getenv('REDIS_HOST', 'localhost')}:{os.getenv('REDIS_PORT', '6379')}"
# Optional permanent store. Unset = Redis only (dev). Firestore is never touched during a match:
# only at account creation / login (rehydrate) and after a match ends (write-behind).
FIRESTORE_PROJECT_ID = os.getenv("FIRESTORE_PROJECT_ID", "")
ROOM_CREATE_TIMEOUT = float(os.getenv("ROOM_CREATE_TIMEOUT", "25"))
OPEN_STATES         = ("ready", "waiting")

# Shared secret between this API and the Godot game servers (they redeem join tickets and report results).
SERVER_KEY          = os.getenv("SERVER_KEY", "")
SESSION_TTL_S       = int(os.getenv("SESSION_TTL_DAYS", "30")) * 86400
TICKET_TTL_S        = 120
MAX_LOGIN_FAILS     = 8          # per account per 15 minutes
MAX_REGISTRATIONS   = 10         # per client address per hour
USERNAME_RE         = re.compile(r"^[A-Za-z0-9_]{3,16}$")

redis_client = None
fs = None                      # google.cloud.firestore.AsyncClient when FIRESTORE_PROJECT_ID is set
_bg_tasks: set = set()


def _background(coro) -> None:
    """Fire-and-forget Firestore write; failures are logged, never surfaced to the player."""
    async def run():
        try:
            await coro
        except Exception as exc:  # noqa: BLE001
            print(json.dumps({"level": "error", "msg": "firestore write failed", "error": str(exc)}), flush=True)
    task = asyncio.create_task(run())
    _bg_tasks.add(task)
    task.add_done_callback(_bg_tasks.discard)


def _player_doc(username: str):
    return fs.collection("players").document(username.lower())


def make_redis(url: str):
    if url.startswith("memory://"):
        import devredis  # provided by backend/dev_stack.py (single-process dev stack)
        return devredis.client()
    return aioredis.from_url(url, decode_responses=True)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global redis_client, fs
    redis_client = make_redis(REDIS_URL)
    await redis_client.ping()
    if FIRESTORE_PROJECT_ID:
        from google.cloud import firestore
        fs = firestore.AsyncClient(project=FIRESTORE_PROJECT_ID)
    if not SERVER_KEY:
        print('{"level":"warn","msg":"SERVER_KEY is not set - game servers cannot authenticate; set it in production"}', flush=True)
    yield
    if _bg_tasks:
        await asyncio.gather(*_bg_tasks, return_exceptions=True)
    if fs:
        fs.close()
    await redis_client.aclose()


app = FastAPI(title="CloudArena API", description="Matchmaking and player stats for CloudArena",
              version="2.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


class Credentials(BaseModel):
    username: str = Field(min_length=3, max_length=16)
    password: str = Field(min_length=8, max_length=128)


class JoinRequest(BaseModel):
    player_name: str | None = None      # ignored: identity comes from the account
    preferred_room: str | None = None


class MatchResult(BaseModel):
    room_id:     str
    winner_name: str
    loser_name:  str | None = None
    duration_s:  float


class TicketRedeem(BaseModel):
    ticket:  str
    room_id: str


# ── Accounts ─────────────────────────────────────────────────────────────────
# user:<name_lower>      HASH  username, salt, hash, created_at, wins, losses
# session:<sha256(tok)>  STR   username (TTL SESSION_TTL_S, refreshed on use)
# ticket:<token>         STR   json {username, room_id} (TTL 120 s, single use)

def _user_key(username: str) -> str:
    return f"user:{username.lower()}"


def _hash_password(password: str, salt: bytes) -> str:
    return hashlib.scrypt(password.encode("utf-8"), salt=salt, n=2 ** 14, r=8, p=1, dklen=32).hex()


def _session_key(token: str) -> str:
    return "session:" + hashlib.sha256(token.encode()).hexdigest()


async def _new_session(username: str) -> str:
    token = secrets.token_urlsafe(32)
    await redis_client.setex(_session_key(token), SESSION_TTL_S, username)
    return token


async def current_user(authorization: str | None = Header(default=None)) -> str:
    """Dependency: the signed-in username for a 'Bearer <token>' header, or 401."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Sign in required")
    token = authorization[7:].strip()
    username = await redis_client.get(_session_key(token))
    if not username:
        raise HTTPException(status_code=401, detail="Session expired - sign in again")
    await redis_client.expire(_session_key(token), SESSION_TTL_S)
    return username


def require_server_key(x_server_key: str | None = Header(default=None)) -> None:
    """Dependency for endpoints only game servers may call."""
    if not SERVER_KEY or not x_server_key or not hmac.compare_digest(x_server_key, SERVER_KEY):
        raise HTTPException(status_code=403, detail="Forbidden")


@app.post("/auth/register")
async def register(creds: Credentials, request: Request):
    if not USERNAME_RE.match(creds.username):
        raise HTTPException(status_code=422, detail="Username: 3-16 letters, digits or underscore")
    ip = request.client.host if request.client else "?"
    rkey = f"ratelimit:register:{ip}"
    count = await redis_client.incr(rkey)
    if count == 1:
        await redis_client.expire(rkey, 3600)
    if count > MAX_REGISTRATIONS:
        raise HTTPException(status_code=429, detail="Too many accounts created from this address")
    salt = secrets.token_bytes(16)
    pw_hash = await asyncio.to_thread(_hash_password, creds.password, salt)
    if fs and not await redis_client.exists(_user_key(creds.username)) and (await _player_doc(creds.username).get()).exists:
        raise HTTPException(status_code=409, detail="That username is taken")
    created = await redis_client.hsetnx(_user_key(creds.username), "username", creds.username)
    if not created:
        raise HTTPException(status_code=409, detail="That username is taken")
    record = {"username": creds.username, "salt": salt.hex(), "hash": pw_hash,
              "created_at": datetime.now(timezone.utc).isoformat(), "wins": 0, "losses": 0}
    await redis_client.hset(_user_key(creds.username), mapping={k: v for k, v in record.items() if k != "username"})
    if fs:
        _background(_player_doc(creds.username).set(record))
    return {"username": creds.username, "token": await _new_session(creds.username)}


@app.post("/auth/login")
async def login(creds: Credentials):
    fkey = f"ratelimit:login:{creds.username.lower()}"
    if int(await redis_client.get(fkey) or 0) >= MAX_LOGIN_FAILS:
        raise HTTPException(status_code=429, detail="Too many failed attempts - try again in 15 minutes")
    user = await redis_client.hgetall(_user_key(creds.username))
    if not user and fs:
        snap = await _player_doc(creds.username).get()       # Redis was wiped/restarted: restore the account
        if snap.exists:
            user = {k: str(v) for k, v in snap.to_dict().items()}
            await redis_client.hset(_user_key(creds.username), mapping=user)
            if int(user.get("wins", 0)) > 0:
                await redis_client.zadd("leaderboard", {user["username"]: int(user["wins"])})
    ok = False
    if user and "hash" in user:
        candidate = await asyncio.to_thread(_hash_password, creds.password, bytes.fromhex(user["salt"]))
        ok = hmac.compare_digest(candidate, user["hash"])
    else:
        # spend the same time as a real check so usernames cannot be probed by timing
        await asyncio.to_thread(_hash_password, creds.password, b"\x00" * 16)
    if not ok:
        n = await redis_client.incr(fkey)
        if n == 1:
            await redis_client.expire(fkey, 900)
        raise HTTPException(status_code=401, detail="Wrong username or password")
    await redis_client.delete(fkey)
    return {"username": user["username"], "token": await _new_session(user["username"])}


@app.post("/auth/logout")
async def logout(authorization: str | None = Header(default=None), _user: str = Depends(current_user)):
    await redis_client.delete(_session_key(authorization[7:].strip()))
    return {"status": "signed_out"}


@app.get("/auth/me")
async def me(username: str = Depends(current_user)):
    user = await redis_client.hgetall(_user_key(username))
    return {"username": username, "wins": int(user.get("wins", 0)), "losses": int(user.get("losses", 0))}


@app.post("/auth/ticket/redeem", dependencies=[Depends(require_server_key)])
async def redeem_ticket(req: TicketRedeem):
    """Game servers exchange the one-time join ticket a client presents for the verified username."""
    key = f"ticket:{req.ticket}"
    raw = await redis_client.get(key)
    if not raw:
        raise HTTPException(status_code=404, detail="Invalid or expired ticket")
    await redis_client.delete(key)
    data = json.loads(raw)
    if data.get("room_id") != req.room_id:
        raise HTTPException(status_code=403, detail="Ticket is for a different room")
    return {"username": data["username"]}


# ── Matchmaking ──────────────────────────────────────────────────────────────
def _room_response(meta: dict) -> dict:
    return {"room_id": meta["room_id"], "server_id": meta.get("server_id"), "ws_url": meta["ws_url"],
            "player_cnt": int(meta.get("player_cnt", 0)), "status": meta.get("status")}


async def _claim_open_room(username: str) -> dict | None:
    """Pop open rooms until one still has a free slot; reserve a slot in it (O(1) per attempt)."""
    skipped: list = []
    try:
        return await _claim_open_room_inner(username, skipped)
    finally:
        for rid in skipped:                       # rooms we could not use stay available for others
            await redis_client.lpush("queue:matchmaking", rid)


async def _claim_open_room_inner(username: str, skipped: list) -> dict | None:
    for _ in range(20):
        room_id = await redis_client.rpop("queue:matchmaking")
        if room_id is None:
            return None
        meta = await redis_client.hgetall(f"room:{room_id}")
        if not meta or meta.get("status") not in OPEN_STATES:
            continue  # stale entry
        if await redis_client.sismember(f"room:{room_id}:users", username):
            skipped.append(room_id)               # never pair an account with itself
            continue
        reserved = await redis_client.hincrby(f"room:{room_id}", "reserved", 1)
        if reserved > 2:
            await redis_client.hincrby(f"room:{room_id}", "reserved", -1)
            continue
        await redis_client.sadd(f"room:{room_id}:users", username)
        await redis_client.expire(f"room:{room_id}:users", 3600)
        if reserved < 2:
            await redis_client.lpush("queue:matchmaking", room_id)  # still one slot left
        return _room_response(meta)
    return None


async def _pick_server() -> str | None:
    """Least-loaded live game host with spare capacity."""
    best, best_load = None, None
    for sid in await redis_client.smembers("servers"):
        if not await redis_client.exists(f"server:{sid}:health"):
            await redis_client.srem("servers", sid)  # dead manager
            continue
        info = await redis_client.hgetall(f"server:{sid}:info")
        load, cap = int(info.get("load", 0)), int(info.get("capacity", 1))
        if load >= cap:
            continue
        if best is None or load < best_load:
            best, best_load = sid, load
    return best


async def _wait_room_open(room_id: str) -> dict:
    loop = asyncio.get_running_loop()
    deadline = loop.time() + ROOM_CREATE_TIMEOUT
    while loop.time() < deadline:
        meta = await redis_client.hgetall(f"room:{room_id}")
        status = meta.get("status")
        if status in OPEN_STATES and meta.get("ws_url"):
            return _room_response(meta)
        if status == "failed":
            raise HTTPException(status_code=503, detail=f"Room creation failed: {meta.get('error')}")
        await asyncio.sleep(0.2)
    raise HTTPException(status_code=504, detail="Timed out waiting for a room to start")


async def _join_creating_room(username: str) -> dict | None:
    """A room that is still booting already has one player; a second player takes the other slot
    instead of starting a second room (cold starts take several seconds)."""
    for room_id in await redis_client.lrange("queue:creating", 0, 9):
        meta = await redis_client.hgetall(f"room:{room_id}")
        if not meta or meta.get("status") != "creating":
            await redis_client.lrem("queue:creating", 0, room_id)
            continue
        if await redis_client.sismember(f"room:{room_id}:users", username):
            continue
        reserved = await redis_client.hincrby(f"room:{room_id}", "reserved", 1)
        if reserved > 2:
            await redis_client.hincrby(f"room:{room_id}", "reserved", -1)
            continue
        await redis_client.sadd(f"room:{room_id}:users", username)
        await redis_client.expire(f"room:{room_id}:users", 3600)
        return await _wait_room_open(room_id)
    return None


async def _create_room(username: str) -> dict:
    server_id = await _pick_server()
    if server_id is None:
        raise HTTPException(status_code=503, detail="No game servers available")
    room_id = uuid.uuid4().hex[:8]
    await redis_client.hset(f"room:{room_id}", mapping={
        "room_id": room_id, "server_id": server_id, "status": "creating", "reserved": 1, "player_cnt": 0,
        "created_at": datetime.now(timezone.utc).isoformat()})
    await redis_client.expire(f"room:{room_id}", 120)
    await redis_client.sadd(f"room:{room_id}:users", username)
    await redis_client.expire(f"room:{room_id}:users", 3600)
    await redis_client.lpush("queue:creating", room_id)
    await redis_client.lpush(f"queue:create:{server_id}", room_id)
    try:
        return await _wait_room_open(room_id)
    finally:
        await redis_client.lrem("queue:creating", 0, room_id)


@app.get("/health")
async def health():
    try:
        await redis_client.ping()
        ok = True
    except Exception:
        ok = False
    return {"status": "ok" if ok else "degraded", "redis": ok,
            "servers": len(await redis_client.smembers("servers")) if ok else 0}


async def _issue_ticket(username: str, room: dict) -> dict:
    ticket = secrets.token_urlsafe(24)
    await redis_client.setex(f"ticket:{ticket}", TICKET_TTL_S, json.dumps({"username": username, "room_id": room["room_id"]}))
    await redis_client.setex(f"user:room:{username.lower()}", 3600, room["room_id"])   # for /match/rejoin
    return {**room, "ticket": ticket, "username": username}


@app.post("/match/join")
async def join_match(req: JoinRequest, username: str = Depends(current_user)):
    """Reserve a slot in an open room, or start a new one. Requires sign-in; returns {room_id, ws_url, ticket, ...}."""
    if req.preferred_room:
        meta = await redis_client.hgetall(f"room:{req.preferred_room}")
        if (meta and meta.get("status") in OPEN_STATES and int(meta.get("reserved", 0)) < 2
                and not await redis_client.sismember(f"room:{req.preferred_room}:users", username)):
            await redis_client.hincrby(f"room:{req.preferred_room}", "reserved", 1)
            await redis_client.sadd(f"room:{req.preferred_room}:users", username)
            return await _issue_ticket(username, _room_response(meta))
    room = await _claim_open_room(username) or await _join_creating_room(username) or await _create_room(username)
    return await _issue_ticket(username, room)


@app.post("/match/rejoin")
async def rejoin_match(username: str = Depends(current_user)):
    """After a dropped connection: a fresh ticket for the match this account is still playing in."""
    room_id = await redis_client.get(f"user:room:{username.lower()}")
    meta = await redis_client.hgetall(f"room:{room_id}") if room_id else None
    if not meta or meta.get("status") != "playing" or not await redis_client.sismember(f"room:{room_id}:users", username):
        raise HTTPException(status_code=404, detail="No running match to return to")
    return await _issue_ticket(username, _room_response(meta))


@app.get("/match/{room_id}")
async def get_match(room_id: str):
    meta = await redis_client.hgetall(f"room:{room_id}")
    if not meta:
        raise HTTPException(status_code=404, detail="Room not found")
    return {**_room_response(meta), "reserved": int(meta.get("reserved", 0)), "updated_at": meta.get("updated_at")}


@app.get("/rooms")
async def list_rooms():
    ids = await redis_client.lrange("queue:matchmaking", 0, 50)
    return {"open_rooms": ids}


# ── Stats ────────────────────────────────────────────────────────────────────
@app.post("/stats/result", dependencies=[Depends(require_server_key)])
async def record_result(result: MatchResult):
    """Only game servers (holding SERVER_KEY) may record results, so wins cannot be forged by clients."""
    winner_key = f"player:stats:{result.winner_name}"
    if await redis_client.exists(_user_key(result.winner_name)):
        await redis_client.hincrby(_user_key(result.winner_name), "wins", 1)
    if result.loser_name and await redis_client.exists(_user_key(result.loser_name)):
        await redis_client.hincrby(_user_key(result.loser_name), "losses", 1)
    pipe = redis_client.pipeline()
    pipe.hincrby(winner_key, "wins", 1)
    pipe.hincrbyfloat(winner_key, "total_playtime_s", result.duration_s)
    pipe.hsetnx(winner_key, "first_win", datetime.now(timezone.utc).isoformat())
    pipe.zincrby("leaderboard", 1, result.winner_name)
    await pipe.execute()
    if fs:
        _background(_persist_match(result))
    return {"status": "recorded", "winner": result.winner_name}


async def _persist_match(result: MatchResult) -> None:
    """Post-match write-behind: permanent history + win/loss counters in one batch."""
    from google.cloud import firestore
    batch = fs.batch()
    batch.set(fs.collection("matches").document(), {
        "room_id": result.room_id, "winner": result.winner_name, "loser": result.loser_name,
        "duration_s": result.duration_s, "finished_at": firestore.SERVER_TIMESTAMP})
    batch.set(_player_doc(result.winner_name), {"wins": firestore.Increment(1)}, merge=True)
    if result.loser_name:
        batch.set(_player_doc(result.loser_name), {"losses": firestore.Increment(1)}, merge=True)
    await batch.commit()


@app.get("/stats/leaderboard")
async def leaderboard(top: int = 10):
    entries = await redis_client.zrevrange("leaderboard", 0, max(0, min(top, 100) - 1), withscores=True)
    board = []
    for rank, (name, score) in enumerate(entries, start=1):
        stats = await redis_client.hgetall(f"player:stats:{name}")
        board.append({"rank": rank, "player_name": name, "wins": int(score),
                      "total_playtime_s": float(stats.get("total_playtime_s", 0)), "first_win": stats.get("first_win")})
    return {"leaderboard": board}


@app.get("/stats/player/{name}")
async def player_stats(name: str):
    stats = await redis_client.hgetall(f"player:stats:{name}")
    if not stats:
        raise HTTPException(status_code=404, detail="Player not found")
    rank = await redis_client.zrevrank("leaderboard", name)
    return {"player_name": name, "wins": int(stats.get("wins", 0)),
            "total_playtime_s": float(stats.get("total_playtime_s", 0)), "first_win": stats.get("first_win"),
            "rank": (rank + 1) if rank is not None else None}
