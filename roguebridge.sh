#!/usr/bin/env bash
# Requisitos: bash, iproute2, nftables, hostapd, dnsmasq, nmcli, iw, grep, sed, awk

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

NFT_TABLE="roguebridge"

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
  sudo $0                              – Modo interactivo (guiado)
  sudo $0 [global options] interactive – Modo interactivo
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
  for c in ip nft hostapd dnsmasq iw grep sed awk; do
    check_cmd "$c"
  done
  # nmcli es opcional; sin él se omite la gestión de NetworkManager
  if ! command -v nmcli >/dev/null 2>&1; then
    log "nmcli no disponible; gestión de NetworkManager desactivada (ok)"
  fi
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

### ====== NFTABLES / NAT ====== ###

# Carga los módulos de kernel necesarios para nftables NAT/MASQUERADE/REDIRECT.
# En Arch Linux son cargables (no built-in); sin ellos los rules fallan con
# "No such file or directory".
_nft_load_modules() {
  local mods=(nf_nat nft_masq nft_chain_nat nft_redir)
  for mod in "${mods[@]}"; do
    modprobe "$mod" 2>/dev/null || true
  done
}

# Reglas de forward sin MitM (llamada internamente)
_nft_forward_base_rules() {
  nft add rule ip "$NFT_TABLE" forward \
    iif "$IFACE_WAN" oif "$IFACE_AP" ct state related,established accept
  nft add rule ip "$NFT_TABLE" forward \
    iif "$IFACE_AP" oif "$IFACE_WAN" accept
  # TCPMSS clamp (equivalente a iptables -t mangle --clamp-mss-to-pmtu)
  nft add rule ip "$NFT_TABLE" forward \
    ip protocol tcp tcp flags '& (syn|rst) == syn' tcp option maxseg size set rt mtu
}

enable_nat() {
  log "Enabling IPv4 forwarding + NAT from $IFACE_AP to $IFACE_WAN"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  _nft_load_modules

  # Tabla limpia
  nft delete table ip "$NFT_TABLE" 2>/dev/null || true
  nft add table ip "$NFT_TABLE"

  # POSTROUTING – MASQUERADE
  nft add chain ip "$NFT_TABLE" postrouting \
    '{ type nat hook postrouting priority srcnat; policy accept; }'
  nft add rule  ip "$NFT_TABLE" postrouting \
    oif "$IFACE_WAN" masquerade

  # FORWARD
  nft add chain ip "$NFT_TABLE" forward \
    '{ type filter hook forward priority filter; policy accept; }'
  _nft_forward_base_rules

  log "NFT NAT + TCPMSS clamp enabled"
}

disable_nat() {
  log "Disabling NAT rules for $IFACE_AP -> $IFACE_WAN"
  nft delete table ip "$NFT_TABLE" 2>/dev/null || true
}

### ====== MitM ====== ###
enable_mitm_rules() {
  local port="$1"
  local scope="$2"

  log "Enabling MitM redirection on $IFACE_AP to local port $port (scope: $scope)"
  _nft_load_modules

  # Asegurar que la tabla existe (mitm puede invocarse sin haber hecho 'up')
  nft add table ip "$NFT_TABLE" 2>/dev/null || true

  # PREROUTING para REDIRECT
  nft add chain ip "$NFT_TABLE" prerouting \
    '{ type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
  nft flush chain ip "$NFT_TABLE" prerouting

  # FORWARD: crear si no existe, luego añadir regla QUIC-drop
  if ! nft list chain ip "$NFT_TABLE" forward >/dev/null 2>&1; then
    nft add chain ip "$NFT_TABLE" forward \
      '{ type filter hook forward priority filter; policy accept; }'
    _nft_forward_base_rules
  fi
  # Bloquear QUIC (UDP 443) para forzar TLS sobre TCP
  nft add rule ip "$NFT_TABLE" forward \
    iif "$IFACE_AP" ip protocol udp udp dport 443 drop

  # Reglas de redirección TCP
  if [ "$scope" = "web" ]; then
    nft add rule ip "$NFT_TABLE" prerouting \
      iif "$IFACE_AP" ip protocol tcp tcp dport 80  redirect to :"$port"
    nft add rule ip "$NFT_TABLE" prerouting \
      iif "$IFACE_AP" ip protocol tcp tcp dport 443 redirect to :"$port"
  else
    nft add rule ip "$NFT_TABLE" prerouting \
      iif "$IFACE_AP" ip protocol tcp redirect to :"$port"
  fi
}

disable_mitm_rules() {
  log "Disabling MitM redirection rules (if any)"

  # Eliminar cadena PREROUTING con sus REDIRECTs
  nft flush  chain ip "$NFT_TABLE" prerouting 2>/dev/null || true
  nft delete chain ip "$NFT_TABLE" prerouting 2>/dev/null || true

  # Reconstruir FORWARD sin la regla QUIC-drop (si la tabla sigue activa)
  if nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then
    if nft list chain ip "$NFT_TABLE" forward >/dev/null 2>&1; then
      nft flush chain ip "$NFT_TABLE" forward
      _nft_forward_base_rules
    fi
  fi
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
  echo "=== nftables ($NFT_TABLE) ==="
  nft list table ip "$NFT_TABLE" 2>/dev/null || echo "(no rules / table not present)"
  echo
  echo "=== IPv4 forwarding ==="
  sysctl net.ipv4.ip_forward || true
  echo
  echo "=== Logs ==="
  echo "Main log: $LOG_FILE"
  echo "hostapd:  $HOSTAPD_LOG"
  echo "dnsmasq:  $DNSMASQ_LOG"
}

### ====== MODO INTERACTIVO ====== ###

# Muestra lista numerada de interfaces del tipo dado y devuelve la elegida en REPLY.
# Uso: _pick_iface wifi|wan <default>
_pick_iface() {
  local type="$1" default="$2"
  local -a list=()
  local d iface

  for d in /sys/class/net/*/; do
    iface="$(basename "$d")"
    case "$type" in
      wifi)
        if [ -d "/sys/class/net/$iface/wireless" ]; then
          list+=("$iface")
        fi
        ;;
      wan)
        [ "$iface" = "lo" ] && continue
        [ -d "/sys/class/net/$iface/wireless" ] && continue
        list+=("$iface")
        ;;
    esac
  done

  if [ "${#list[@]}" -eq 0 ]; then
    echo "    (ninguna detectada automáticamente)"
    _prompt "Introduce el nombre manualmente" "$default"
    return
  fi

  # Índice del default para mostrarlo preseleccionado
  local default_idx=1 i
  for i in "${!list[@]}"; do
    if [ "${list[$i]}" = "$default" ]; then
      default_idx=$((i + 1))
    fi
  done

  # Lista numerada
  for i in "${!list[@]}"; do
    printf '    %d) %s\n' "$((i + 1))" "${list[$i]}"
  done

  # Lectura de la selección
  local val
  read -rp "  Selecciona [${default_idx}]: " val </dev/tty
  val="${val:-$default_idx}"

  # Resolver número → nombre; si escriben el nombre directamente, se acepta
  if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ] && [ "$val" -le "${#list[@]}" ]; then
    REPLY="${list[$((val - 1))]}"
  else
    REPLY="$val"
  fi
}

# Lee un valor del terminal; deja REPLY con el resultado (o el default)
_prompt() {
  local prompt="$1" default="$2" val
  read -rp "  $prompt [${default}]: " val </dev/tty
  REPLY="${val:-$default}"
}

# Igual que _prompt pero oculta la entrada (para contraseñas)
_prompt_secret() {
  local prompt="$1" default="$2" val
  read -rsp "  $prompt [${default:+****}]: " val </dev/tty
  printf '\n' >/dev/tty
  REPLY="${val:-$default}"
}

do_interactive() {
  check_root
  ensure_deps

  printf '\n'
  echo "╔══════════════════════════════════════════╗"
  echo "║     RogueBridge – Configuración guiada   ║"
  echo "╚══════════════════════════════════════════╝"
  printf '\n'

  # ── Interfaces ──────────────────────────────────
  echo "── Interfaces ───────────────────────────────"
  echo "  Interfaz AP (WiFi):"
  _pick_iface wifi "$IFACE_AP"
  IFACE_AP="$REPLY"

  printf '\n'
  echo "  Interfaz WAN (salida a Internet):"
  _pick_iface wan "$IFACE_WAN"
  IFACE_WAN="$REPLY"
  printf '\n'

  # ── AP ───────────────────────────────────────────
  echo "── Configuración del AP ─────────────────────"
  _prompt        "SSID"                     "$SSID";           SSID="$REPLY"
  _prompt_secret "Contraseña WPA2 (≥8 ch)"  "$WPA_PASSPHRASE"; WPA_PASSPHRASE="$REPLY"
  _prompt        "IP del AP"                "$AP_IP";          AP_IP="$REPLY"
  _prompt        "Canal WiFi (1-13)"        "$CHANNEL";        CHANNEL="$REPLY"
  _prompt        "Código de país (US/ES/…)" "$COUNTRY";        COUNTRY="$REPLY"
  printf '\n'

  # ── DHCP (opcional) ──────────────────────────────
  echo "── DHCP (Enter para conservar defaults) ─────"
  _prompt "DHCP inicio" "$DHCP_START"; DHCP_START="$REPLY"
  _prompt "DHCP fin"    "$DHCP_END";   DHCP_END="$REPLY"
  printf '\n'

  # ── Acción ───────────────────────────────────────
  echo "── Acción ───────────────────────────────────"
  echo "  1) up        – Levantar el AP"
  echo "  2) down      – Bajar el AP"
  echo "  3) mitm on   – Activar redirección MitM"
  echo "  4) mitm off  – Desactivar MitM"
  echo "  5) status    – Ver estado actual"
  printf '\n'
  _prompt "Selecciona acción" "1"
  local choice="$REPLY"

  case "$choice" in
    1) do_up ;;
    2) do_down ;;
    3)
      printf '\n'
      echo "── MitM ─────────────────────────────────────"
      _prompt "Puerto proxy local" "$PROXY_PORT"
      PROXY_PORT="$REPLY"
      _prompt "Scope  (web = 80/443 · all = todo TCP)" "$MITM_SCOPE"
      local scope="$REPLY"
      case "$scope" in
        web|all) ;;
        *) die "Scope inválido: $scope (usa web o all)" ;;
      esac
      do_mitm_on "$PROXY_PORT" "$scope"
      ;;
    4) do_mitm_off ;;
    5) health_checks ;;
    *) die "Opción inválida: $choice" ;;
  esac
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
    up|down|status|interactive|i)
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
  ACTION="interactive"
fi

case "$ACTION" in
  up)                do_up ;;
  down)              do_down ;;
  status)            health_checks ;;
  interactive|i)     do_interactive ;;
  mitm)
    case "${ACTION_ARGS[0]:-}" in
      on)  do_mitm_on "${ACTION_ARGS[1]:-}" "${ACTION_ARGS[2]:-}" ;;
      off) do_mitm_off ;;
      *)   echo "Uso: $0 [opts] mitm on [port] [web|all] | mitm off"; exit 1 ;;
    esac
    ;;
  *) usage; exit 1 ;;
esac
