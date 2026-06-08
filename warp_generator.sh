#!/usr/bin/env bash

# Check for required tools
for cmd in curl jq wg openssl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: '$cmd' is not installed. Please install it first."
        exit 1
    fi
done

echo "Origin: Cloudflare WARP Config Generator (v0a2158)"
echo "--------------------------------------------------"

# 1. Generate WireGuard Keys (Curve25519)
PRIVATE_KEY=$(wg genkey)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)

# 2. Generate random install_id and fcm_token (matching JS logic)
INSTALL_ID=$(openssl rand -hex 6 | cut -c1-11)
FCM_SUFFIX=$(openssl rand -hex 67)
FCM_TOKEN="${INSTALL_ID}:APA91b${FCM_SUFFIX}"

# Prepare current time in ISO format with +08:00 timezone
TOS_DATE=$(date -u +"%Y-%m-%dT%H:%M:%S.000+08:00")

# API Update Details and Headers
API_REG_URL="https://api.cloudflareclient.com/v0a2158/reg"
CLIENT_VERSION="a-6.10-2158"
USER_AGENT="okhttp/3.12.1"

# 3. Prepare JSON Body
REG_BODY=$(jq -n \
  --arg key "$PUBLIC_KEY" \
  --arg id "$INSTALL_ID" \
  --arg token "$FCM_TOKEN" \
  --arg tos "$TOS_DATE" \
  '{
    "key": $key,
    "install_id": $id,
    "fcm_token": $token,
    "referrer": "",
    "warp_enabled": true,
    "tos": $tos,
    "model": "Xiaomi POCO X2",
    "type": "Android",
    "locale": "en_US"
  }')

echo "[*] Registering account (POST)..."
REG_RESPONSE=$(curl --silent --request POST "$API_REG_URL" \
  --header "Content-Type: application/json; charset=UTF-8" \
  --header "User-Agent: $USER_AGENT" \
  --header "CF-Client-Version: $CLIENT_VERSION" \
  --data "$REG_BODY")

# Extract ID and Token from the response
REG_ID=$(echo "$REG_RESPONSE" | jq -r '.id // empty')
REG_TOKEN=$(echo "$REG_RESPONSE" | jq -r '.token // empty')

if [ -z "$REG_ID" ] || [ -z "$REG_TOKEN" ] || [ "$REG_ID" == "null" ]; then
    echo "Error: Registration failed. API Response:"
    echo "$REG_RESPONSE"
    exit 1
fi

echo "[*] Fetching profile details (GET)..."
INFO_RESPONSE=$(curl --silent --request GET "${API_REG_URL}/${REG_ID}" \
  --header "User-Agent: $USER_AGENT" \
  --header "CF-Client-Version: $CLIENT_VERSION" \
  --header "Authorization: Bearer $REG_TOKEN")

# Parse IP addresses and Peer data for the output
ADDR_V4=$(echo "$INFO_RESPONSE" | jq -r '.config.interface.addresses.v4 // empty')
ADDR_V6=$(echo "$INFO_RESPONSE" | jq -r '.config.interface.addresses.v6 // empty')
PEER_PUB=$(echo "$INFO_RESPONSE" | jq -r '.config.peers[0].public_key // empty')
ENDPOINT=$(echo "$INFO_RESPONSE" | jq -r '.config.peers[0].endpoint.host // empty')

if [ -z "$ADDR_V4" ]; then
    echo "Error: Failed to fetch profile details or invalid response. API Response:"
    echo "$INFO_RESPONSE"
    exit 1
fi

# 4. Create WireGuard .conf File
CONFIG_FILE="warp.conf"

cat << EOF > "$CONFIG_FILE"
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $ADDR_V4
Address = $ADDR_V6
DNS = 1.1.1.1

[Peer]
PublicKey = $PEER_PUB
Endpoint = $ENDPOINT
AllowedIPs = 0.0.0.0/0
AllowedIPs = ::/0
EOF

echo "--------------------------------------------------"
echo "Success! Configuration saved to '$CONFIG_FILE'."
echo "--------------------------------------------------"
cat "$CONFIG_FILE"

