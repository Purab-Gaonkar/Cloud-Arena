import asyncio
import json
import random
import math
from datetime import datetime
import websockets

# Game state
players = {}
next_player_id = 1
game_active = True
safe_zone_center = (1000, 1000)
safe_zone_radius = 300
safe_zone_shrink_rate = 0.95  # Shrink by 5% each update

class GamePlayer:
    def __init__(self, player_id, name, websocket):
        self.player_id = player_id
        self.name = name
        self.websocket = websocket
        self.x = random.randint(100, 1900)
        self.y = random.randint(100, 1900)
        self.rotation = 0
        self.health = 100
        self.alive = True
    
    async def send(self, data):
        try:
            await self.websocket.send(json.dumps(data))
        except Exception as e:
            print(f"Error sending to player {self.player_id}: {e}")
    
    async def broadcast(self, data):
        """Send message to all players"""
        tasks = []
        for pid, player in players.items():
            if player.alive:
                tasks.append(player.send(data))
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

async def handle_client(websocket, path):
    global next_player_id, safe_zone_center, safe_zone_radius
    
    player = None
    
    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                msg_type = data.get("type", "")
                
                if msg_type == "join":
                    # New player joining
                    player_id = next_player_id
                    next_player_id += 1
                    player_name = data.get("player_name", f"Player{player_id}")
                    
                    player = GamePlayer(player_id, player_name, websocket)
                    players[player_id] = player
                    
                    print(f"[JOIN] {player_name} joined (ID: {player_id}) - Total: {len(players)}")
                    
                    # Tell this player they joined
                    await player.send({
                        "type": "join_success",
                        "player_id": player_id,
                        "spawn_x": player.x,
                        "spawn_y": player.y
                    })
                    
                    # Tell all players about the new player
                    await player.broadcast({
                        "type": "player_joined",
                        "player_id": player_id,
                        "player_name": player_name,
                        "spawn_x": player.x,
                        "spawn_y": player.y
                    })
                
                elif msg_type == "player_update":
                    if player:
                        player.x = data.get("x", player.x)
                        player.y = data.get("y", player.y)
                        player.rotation = data.get("rotation", player.rotation)
                        
                        # Broadcast to other players (throttled for bandwidth)
                        await player.broadcast({
                            "type": "player_update",
                            "player_id": player.player_id,
                            "x": player.x,
                            "y": player.y,
                            "rotation": player.rotation
                        })
                
                elif msg_type == "shoot":
                    if player:
                        shooter_id = player.player_id
                        shoot_x = data.get("x", player.x)
                        shoot_y = data.get("y", player.y)
                        dir_x = data.get("dir_x", 1)
                        dir_y = data.get("dir_y", 0)
                        
                        # Check for hits (simple raycast)
                        # Bullet travels and checks collision with other players
                        await check_bullet_hit(shooter_id, shoot_x, shoot_y, dir_x, dir_y)
                        
                        # Notify all players of the shot
                        await player.broadcast({
                            "type": "shoot",
                            "player_id": shooter_id,
                            "x": shoot_x,
                            "y": shoot_y,
                            "dir_x": dir_x,
                            "dir_y": dir_y
                        })
                
                else:
                    print(f"Unknown message type: {msg_type}")
            
            except json.JSONDecodeError:
                print(f"Invalid JSON received")
            except Exception as e:
                print(f"Error handling message: {e}")
    
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        if player:
            players.pop(player.player_id, None)
            print(f"[LEAVE] {player.name} left (ID: {player.player_id}) - Total: {len(players)}")
            
            # Notify all players
            await player.broadcast({
                "type": "player_left",
                "player_id": player.player_id
            })

async def check_bullet_hit(shooter_id, shoot_x, shoot_y, dir_x, dir_y):
    """Simple bullet-player collision detection"""
    hit_radius = 20  # Bullet radius for collision
    bullet_speed = 500
    bullet_distance = 1000  # Max distance bullet travels
    
    # Normalize direction
    dir_length = math.sqrt(dir_x**2 + dir_y**2)
    if dir_length > 0:
        dir_x /= dir_length
        dir_y /= dir_length
    
    # Check collision with other players
    for player_id, target in players.items():
        if player_id == shooter_id or not target.alive:
            continue
        
        # Vector from bullet start to target
        dx = target.x - shoot_x
        dy = target.y - shoot_y
        
        # Distance along bullet direction
        dot = dx * dir_x + dy * dir_y
        
        # Point on bullet line closest to target
        closest_x = shoot_x + dot * dir_x
        closest_y = shoot_y + dot * dir_y
        
        # Distance from target to bullet line
        dist_x = target.x - closest_x
        dist_y = target.y - closest_y
        distance = math.sqrt(dist_x**2 + dist_y**2)
        
        # Check if within range and hit
        if 0 < dot < bullet_distance and distance < hit_radius + 16:
            # Hit!
            damage = 25
            target.health -= damage
            
            print(f"[HIT] Player {shooter_id} hit Player {player_id} ({damage} damage)")
            
            if target.health <= 0:
                target.alive = False
                print(f"[KILL] Player {player_id} eliminated by Player {shooter_id}")
            
            # Send hit notification
            await target.send({
                "type": "hit",
                "player_id": player_id,
                "damage": damage,
                "health": max(0, target.health)
            })
            
            # Only one hit per shot
            break

async def game_loop():
    """Main game loop - updates and shrinks safe zone"""
    global safe_zone_center, safe_zone_radius
    
    while game_active:
        await asyncio.sleep(2)  # Update every 2 seconds
        
        # Shrink safe zone
        safe_zone_radius *= safe_zone_shrink_rate
        if safe_zone_radius < 50:
            safe_zone_radius = 50
        
        # Notify all players of safe zone update
        alive_players = sum(1 for p in players.values() if p.alive)
        
        tasks = []
        for player in players.values():
            if player.alive:
                tasks.append(player.send({
                    "type": "game_update",
                    "players_alive": alive_players
                }))
                tasks.append(player.send({
                    "type": "safe_zone",
                    "center_x": safe_zone_center[0],
                    "center_y": safe_zone_center[1],
                    "radius": safe_zone_radius
                }))
        
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        
        # Check if game should end
        if alive_players <= 1:
            for player in players.values():
                if player.alive:
                    await player.broadcast({
                        "type": "game_over",
                        "winner": player.name
                    })
                    print(f"[GAME OVER] {player.name} won!")
                    break
            
            # Reset game
            await asyncio.sleep(5)
            safe_zone_radius = 300
            players.clear()

async def main():
    print("Starting Battle Royale Test Server on ws://localhost:8765")
    print("Max players: 30")
    
    # Start game loop
    asyncio.create_task(game_loop())
    
    # Start server
    async with websockets.serve(handle_client, "localhost", 8765):
        print("Server ready! Waiting for connections...")
        await asyncio.Future()  # Run forever

if __name__ == "__main__":
    asyncio.run(main())
