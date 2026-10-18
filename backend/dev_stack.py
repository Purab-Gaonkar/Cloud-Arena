"""
Single-process development stack (no Docker, no Redis server needed).

Starts the matchmaking API and one room manager in the same asyncio loop, sharing an in-process
fake Redis, and spawns real headless Godot dedicated servers on demand.

    python backend/dev_stack.py            # API on :8000, relay on :8765
    GODOT_BIN=/path/to/godot python backend/dev_stack.py

Then point the game's ONLINE menu at http://127.0.0.1:8000.
"""
import asyncio
import importlib.util
import os
import sys
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

os.environ.setdefault("REDIS_URL", "memory://")
os.environ.setdefault("GODOT_PROJECT", str(ROOT))
os.environ.setdefault("GODOT_BIN", r"E:\Godot\Godot_v4.7.1-stable_win64_console.exe")
os.environ.setdefault("PORT", "8765")
os.environ.setdefault("PUBLIC_WS_BASE", "ws://127.0.0.1:" + os.environ["PORT"])
os.environ.setdefault("SERVER_KEY", "dev-server-key")
os.environ.setdefault("API_URL", "http://127.0.0.1:8000")

import fakeredis  # noqa: E402

_shared = fakeredis.FakeServer()
devredis = types.ModuleType("devredis")
devredis.client = lambda: fakeredis.FakeAsyncRedis(server=_shared, decode_responses=True)
sys.modules["devredis"] = devredis


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


async def main() -> None:
    import uvicorn

    api = load("cloud_arena_api", HERE / "matchmaking_api" / "main.py")
    manager = load("cloud_arena_manager", HERE / "game_server" / "server.py")

    config = uvicorn.Config(api.app, host="0.0.0.0", port=int(os.getenv("API_PORT", "8000")), log_level="warning")
    server = uvicorn.Server(config)
    mgr = manager.Manager()

    api_task = asyncio.create_task(server.serve())
    await asyncio.sleep(0.5)               # let the API create its Redis client first
    mgr_task = asyncio.create_task(mgr.run())
    print(f"[dev_stack] API http://127.0.0.1:{config.port}   relay {os.environ['PUBLIC_WS_BASE']}", flush=True)
    await asyncio.gather(api_task, mgr_task)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
