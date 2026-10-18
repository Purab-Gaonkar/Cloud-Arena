# -- Game host: Python room manager + headless Godot dedicated servers ----------
# Build from the REPOSITORY ROOT (the Godot project is part of the image):
#   docker build -f backend/game_server/Dockerfile -t cloud-arena/game-server .
FROM python:3.12-slim

ARG GODOT_VERSION=4.7.1-stable
ENV DEBIAN_FRONTEND=noninteractive

# Libraries the (headless) Godot binary still links against
RUN apt-get update && apt-get install -y --no-install-recommends         ca-certificates curl unzip libfontconfig1 libx11-6 libxcursor1 libxinerama1         libxrandr2 libxi6 libgl1 libasound2 libpulse0 &&     rm -rf /var/lib/apt/lists/*

# Godot Linux build (the same binary also acts as the dedicated server runtime)
RUN curl -fsSL -o /tmp/godot.zip         "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" &&     unzip -q /tmp/godot.zip -d /opt &&     mv /opt/Godot_v${GODOT_VERSION}_linux.x86_64 /usr/local/bin/godot &&     chmod +x /usr/local/bin/godot && rm /tmp/godot.zip

RUN groupadd -r cloudapp && useradd -r -m -g cloudapp cloudapp
ENV HOME=/home/cloudapp

# The game project (see .dockerignore for what is left out)
WORKDIR /game
COPY project.godot export_presets.cfg icon.svg ./
COPY scenes ./scenes
COPY scripts ./scripts
COPY assets ./assets
# Bake Godot's import cache so servers start in about a second instead of re-importing assets
RUN godot --headless --path /game --import || true
RUN chown -R cloudapp:cloudapp /game

# Room manager
WORKDIR /srv
COPY backend/game_server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/game_server/server.py .

ENV GODOT_BIN=/usr/local/bin/godot     GODOT_PROJECT=/game     PORT=8765
EXPOSE 8765
USER cloudapp
CMD ["python", "-u", "server.py"]
