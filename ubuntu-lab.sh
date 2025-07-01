#!/bin/bash

NETWORK_NAME=$1
CONTAINER_NAME=$2
USE_VOLUME=$3  # pass literally "volume" if you want volume mount
VOLUME_PATH=$4  

if [ -z "$NETWORK_NAME" ] || [ -z "$CONTAINER_NAME" ]; then
  echo "Usage: $0 <network_name> <container_name> [volume] [volume_name]"
  exit 1
fi
if [[ "$USE_VOLUME" == "volume" && -z "$VOLUME_PATH" ]]; then
  echo "specify volume path"
  exit 1
fi

if docker network ls --format '{{.Name}}' | grep -wq "$NETWORK_NAME"; then
  echo "Network '$NETWORK_NAME' already exists."
else
  echo "Creating network '$NETWORK_NAME'..."
  docker network create \
    --driver bridge \
    --subnet 172.25.0.0/16 \
    --gateway 172.25.0.1 \
    "$NETWORK_NAME"
fi

assigned_ips=$(docker network inspect "$NETWORK_NAME" -f '{{range .Containers}}{{.IPv4Address}}{{"\n"}}{{end}}' | cut -d/ -f1)

# Find a free IP in subnet 172.25.0.0/16 (e.g. from 172.25.0.2 to 172.25.255.254)
function ip_to_int() {
  local IFS=.
  read -r i1 i2 i3 i4 <<< "$1"
  echo $((i1 * 256 ** 3 + i2 * 256 ** 2 + i3 * 256 + i4))
}

function int_to_ip() {
  local ip=$1
  echo "$(( (ip >> 24) & 255 )).$(( (ip >> 16) & 255 )).$(( (ip >> 8) & 255 )).$(( ip & 255 ))"
}

network_base="172.25.0.0"
network_base_int=$(ip_to_int "$network_base")
start_ip_int=$((network_base_int + 2))    # skip gateway and network addr
end_ip_int=$((network_base_int + 65534)) # 172.25.255.254

declare -A taken_ips
for ip in $assigned_ips; do
  taken_ips[$(ip_to_int $ip)]=1
done

free_ip=""
for ((ip_int=start_ip_int; ip_int<=end_ip_int; ip_int++)); do
  if [ -z "${taken_ips[$ip_int]}" ]; then
    free_ip=$(int_to_ip $ip_int)
    break
  fi
done

if [ -z "$free_ip" ]; then
  echo "No free IPs available in network $NETWORK_NAME"
  exit 1
fi

echo "Assigning IP $free_ip to container $CONTAINER_NAME"

volume_flag=""
if [ "$USE_VOLUME" == "volume" ]; then
  volume_flag="-v "$VOLUME_PATH":/data"
fi

docker run -it \
  --name "$CONTAINER_NAME" \
  --network "$NETWORK_NAME" \
  --ip "$free_ip" \
  $volume_flag \
  ubuntu:22.04



