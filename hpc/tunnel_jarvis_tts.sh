#!/bin/bash

# Check if a node name is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <NODE>"
  exit 1
fi

NODE=$1

# Execute the SSH command to the provided node, jumping through Jarvis, 
# and forwarding all necessary ports over a single connection
ssh -i ~/.ssh/hpc_tunnel_key -J ccollard@jarvis.stevens.edu \
  -L 0.0.0.0:9090:localhost:9090 \
  -L 0.0.0.0:8181:localhost:8181 \
  -L 0.0.0.0:5000:localhost:5000 \
  ccollard@$NODE
