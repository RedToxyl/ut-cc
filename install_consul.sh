#!/usr/bin/env bash
# Bootstrap a student machine into Consul and prepare SSH access for Nagios.
set -euo pipefail

CONSUL_VERSION="${CONSUL_VERSION:-1.20.1}"

CONSUL_SERVER_DEFAULT="172.17.88.109"
CONSUL_DATACENTER_DEFAULT="dc1"
NAGIOS_PUBKEY_DEFAULT="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4mdOW9F9z8oTUaOU4koeaL9ZWL2dw/SZczLXb+V0ey"

CONSUL_SERVER="${CONSUL_SERVER_OVERRIDE:-$CONSUL_SERVER_DEFAULT}"
CONSUL_DATACENTER="${CONSUL_DATACENTER_OVERRIDE:-$CONSUL_DATACENTER_DEFAULT}"
NAGIOS_PUBKEY_VALUE="${NAGIOS_PUBKEY_OVERRIDE:-$NAGIOS_PUBKEY_DEFAULT}"
NAGIOS_PUBKEY="$(printf '%s' "$NAGIOS_PUBKEY_VALUE")"
CONSUL_USER="${CONSUL_USER:-consul}"
CONSUL_CONFIG_DIR="/etc/consul.d"
CONSUL_DATA_DIR="/opt/consul"
CONSUL_SERVICE_NAME="nagios-host"

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi

if ! id -u "$CONSUL_USER" >/dev/null 2>&1; then
  echo "User '$CONSUL_USER' does not exist. Please create it before running this script."
  exit 1
fi

# Ensure the consul user can log in via SSH (has a real shell and home)
CONSUL_HOME_CURRENT="$(getent passwd "$CONSUL_USER" | cut -d: -f6)"
CONSUL_SHELL_CURRENT="$(getent passwd "$CONSUL_USER" | cut -d: -f7)"
if [[ "$CONSUL_SHELL_CURRENT" =~ (nologin|false)$ ]]; then
  chsh -s /bin/bash "$CONSUL_USER"
fi
if [[ -z "$CONSUL_HOME_CURRENT" || "$CONSUL_HOME_CURRENT" == "/" || ! -d "$CONSUL_HOME_CURRENT" ]]; then
  CONSUL_HOME_CURRENT="/home/$CONSUL_USER"
  install -d -m 0750 -o "$CONSUL_USER" -g "$CONSUL_USER" "$CONSUL_HOME_CURRENT"
  usermod -d "$CONSUL_HOME_CURRENT" "$CONSUL_USER"
fi
# If account is locked, unlock it (user created with password 'consul' is fine)
if passwd -S "$CONSUL_USER" 2>/dev/null | awk '{print $2}' | grep -q '^L$'; then
  passwd -u "$CONSUL_USER" >/dev/null
fi

if [[ -z "${NAGIOS_PUBKEY// }" || "$NAGIOS_PUBKEY" == "__REPLACE_WITH_NAGIOS_PUBLIC_KEY__" ]]; then
  echo "Nagios SSH public key is not embedded. Set NAGIOS_PUBKEY env var and re-run."
  exit 1
fi

echo "[1/7] Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y unzip curl jq openssh-server
systemctl enable --now ssh >/dev/null 2>&1 || true

CONSUL_ARCHIVE="/tmp/consul_${CONSUL_VERSION}_linux_amd64.zip"
if ! command -v consul >/dev/null 2>&1 || ! consul version | awk 'NR==1{ver=$2; sub(/^v/,"",ver); print ver}' | grep -qx "${CONSUL_VERSION}"; then
  echo "[2/7] Installing Consul ${CONSUL_VERSION}..."
  curl -fsSL "https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip" -o "$CONSUL_ARCHIVE"
  unzip -o "$CONSUL_ARCHIVE" -d /usr/local/bin
  chmod 0755 /usr/local/bin/consul
else
  echo "[2/7] Consul ${CONSUL_VERSION} already installed."
fi

echo "[3/7] Preparing Consul directories..."
install -d -m 0755 -o "$CONSUL_USER" -g "$CONSUL_USER" "$CONSUL_CONFIG_DIR"
install -d -m 0755 -o "$CONSUL_USER" -g "$CONSUL_USER" "$CONSUL_CONFIG_DIR"/certs
install -d -m 0755 -o "$CONSUL_USER" -g "$CONSUL_USER" "$CONSUL_DATA_DIR"

HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "$HOST_IP" ]]; then
  HOST_IP="$(ip -4 addr show scope global | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1)"
fi
SERVICE_ID="${CONSUL_SERVICE_NAME}-${HOST_FQDN}"

cat >"${CONSUL_CONFIG_DIR}/agent.hcl" <<EOF
datacenter = "${CONSUL_DATACENTER}"
node_name  = "${HOST_FQDN}"
data_dir   = "${CONSUL_DATA_DIR}"
bind_addr  = "0.0.0.0"
client_addr = "0.0.0.0"
retry_join = ["${CONSUL_SERVER}"]
EOF
chown "$CONSUL_USER:$CONSUL_USER" "${CONSUL_CONFIG_DIR}/agent.hcl"

cat >"${CONSUL_CONFIG_DIR}/nagios-host.json" <<EOF
{
  "service": {
    "name": "${CONSUL_SERVICE_NAME}",
    "id": "${SERVICE_ID}",
    "address": "${HOST_IP}",
    "port": 22,
    "tags": ["monitor", "students"],
    "meta": {
      "fqdn": "${HOST_FQDN}",
      "ssh_user": "${CONSUL_USER}"
    },
    "check": {
      "name": "consul-tcp-8301",
      "tcp": "127.0.0.1:8301",
      "interval": "30s",
      "timeout": "5s"
    }
  }
}
EOF
chown "$CONSUL_USER:$CONSUL_USER" "${CONSUL_CONFIG_DIR}/nagios-host.json"

echo "[4/7] Configuring SSH access for Nagios..."
CONSUL_HOME="$(getent passwd "$CONSUL_USER" | cut -d: -f6)"
install -d -m 0700 -o "$CONSUL_USER" -g "$CONSUL_USER" "${CONSUL_HOME}/.ssh"
AUTHORIZED_KEYS="${CONSUL_HOME}/.ssh/authorized_keys"
if ! grep -Fqx "$NAGIOS_PUBKEY" "$AUTHORIZED_KEYS" 2>/dev/null; then
  printf '%s\n' "$NAGIOS_PUBKEY" >>"$AUTHORIZED_KEYS"
fi
chown "$CONSUL_USER:$CONSUL_USER" "$AUTHORIZED_KEYS"
chmod 0600 "$AUTHORIZED_KEYS"

echo "[5/7] Granting passwordless sudo to ${CONSUL_USER}..."
echo "${CONSUL_USER} ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-consul-nagios
chmod 0440 /etc/sudoers.d/90-consul-nagios

echo "[6/7] Installing systemd unit..."
cat >/etc/systemd/system/consul.service <<'EOF'
[Unit]
Description=Consul Agent
Documentation=https://www.consul.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=consul
Group=consul
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/usr/local/bin/consul reload
KillMode=process
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now consul

echo "[7/7] Reloading Consul configuration..."
consul validate "${CONSUL_CONFIG_DIR}" >/dev/null
consul reload >/dev/null

echo "Consul agent is running and registered as ${SERVICE_ID}."
echo "Nagios will discover this host as ${HOST_FQDN} (students hostgroup)."
