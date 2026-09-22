#!/bin/bash

# Check if a node name is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <NODE>"
  exit 1
fi

NODE=$1

# Execute the SSH command to the provided node, jumping through Jarvis,
# and forwarding all necessary ports over a single connection. Ports
# 8181-8188 are every tts-serve engine's default port (see
# app/config.py DEFAULT_TTS_ENGINE_PROFILES / hpc/start_all_tts_engines.sh);
# forwarding all of them is harmless even if only some are actually running
# remotely, and lets the "TTS Model" dropdown switch engines with no
# re-tunneling needed.
ssh -i ~/.ssh/hpc_tunnel_key -J ccollard@jarvis.stevens.edu \
  -L 0.0.0.0:9090:localhost:9090 \
  -L 0.0.0.0:8181:localhost:8181 \
  -L 0.0.0.0:8182:localhost:8182 \
  -L 0.0.0.0:8183:localhost:8183 \
  -L 0.0.0.0:8184:localhost:8184 \
  -L 0.0.0.0:8185:localhost:8185 \
  -L 0.0.0.0:8186:localhost:8186 \
  -L 0.0.0.0:8187:localhost:8187 \
  -L 0.0.0.0:8188:localhost:8188 \
  -L 0.0.0.0:5000:localhost:5000 \
  ccollard@$NODE
