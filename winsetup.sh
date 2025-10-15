#!/bin/bash
set -Eeuo pipefail

# ====== CONFIG ======
IMG_URL="https://www.dropbox.com/scl/fi/wozij42y4dsj4begyjwj1/10-lite.img?rlkey=lyb704acrmr1k023b81w3jpsk&st=e3b81z4i&dl=1"
IMG_DIR="/var/lib/libvirt/images"
IMG_FILE="$IMG_DIR/10-lite.img"
RDP_PORT="${RDP_PORT:-2025}"      # đổi nhanh: RDP_PORT=4000 ./winsetup.sh
VM_NAME="${VM_NAME:-win10lite}"
VM_RAM="${VM_RAM:-2048}"          # MB
VM_CPU="${VM_CPU:-2}"             # vCPU
LOG_FILE="${LOG_FILE:-/var/log/winsetup.log}"

# ====== HELPERS ======
ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*"; }
hr(){ echo "------------------------------------------------------------------"; }

apt_wait_unlock(){
  local timeout="${1:-180}" waited=0
  local locks=(/var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock)
  while :; do
    local busy=0
    if pgrep -fa 'apt|dpkg|unattended' >/dev/null 2>&1; then busy=1; fi
    if (( !busy )); then
      for f in "${locks[@]}"; do [[ -e "$f" ]] && { busy=1; break; }; done
    fi
    (( !busy )) && break
    (( waited++ ))
    if (( waited>=timeout )); then
      systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
      systemctl kill --kill-who=main --signal=TERM apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
      sleep 5; waited=0
    else
      sleep 1
    fi
  done
}

apt_safe_install(){
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    log "→ Chờ APT sẵn sàng"; apt_wait_unlock 60
    dpkg --configure -a >/dev/null 2>&1 || true
    log "→ apt update"; apt-get update -y || true
    local pkgs=(qemu-system-x86 qemu-utils wget curl)
    apt-cache show ufw >/dev/null 2>&1 && pkgs+=(ufw)
    for i in 1 2 3; do
      log "→ apt install (lần $i)"
      if apt-get install -y "${pkgs[@]}"; then return 0; fi
      log "⚠️  apt-get install lỗi, chờ nhả lock rồi thử lại"
      apt_wait_unlock 60; sleep 3
    done
    log "❌ apt-get install thất bại sau 3 lần"; return 1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y qemu-kvm qemu-img wget curl || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y qemu-kvm qemu-img wget curl || true
  else
    log "❌ Không có apt/dnf/yum"; return 1
  fi
}

open_ports(){
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    ufw allow "${port}/udp" >/dev/null 2>&1 || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    iptables -I INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
  fi
  if command -v nft >/dev/null 2>&1; then
    # Bảo thủ: chỉ thêm rule nếu đã có table/chain filter; nếu không có thì bỏ qua.
    nft list table inet filter >/dev/null 2>&1 && {
      nft add rule inet filter input tcp dport "$port" accept >/dev/null 2>&1 || true
      nft add rule inet filter input udp dport "$port" accept >/dev/null 2>&1 || true
    }
  fi
}

main(){
  # log ra file & màn hình
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  hr; log "START winsetup (log: $LOG_FILE)"; hr

  [[ "$(id -u)" -eq 0 ]] && SUDO="" || SUDO="sudo"
  $SUDO mkdir -p "$IMG_DIR"
  cd "$IMG_DIR"

  log "B1/6 Cài gói cần thiết"
  apt_safe_install

  log "B2/6 Kiểm tra tăng tốc KVM"
  $SUDO modprobe kvm 2>/dev/null || true
  $SUDO modprobe kvm-intel 2>/dev/null || $SUDO modprobe kvm-amd 2>/dev/null || true
  [[ -e /dev/kvm ]] && log "✔ /dev/kvm sẵn sàng" || log "ℹ️  Không có /dev/kvm → dùng TCG (chậm hơn)"

  log "B3/6 Tải/kiểm tra image"
  if [[ ! -f "$IMG_FILE" ]]; then
    log "→ Tải: $IMG_URL"
    wget --progress=dot:giga -O "$IMG_FILE" "$IMG_URL"
  else
    log "→ Đã có: $IMG_FILE"
  fi
  qemu-img info "$IMG_FILE" || true
  IMG_FORMAT="$(qemu-img info --output=json "$IMG_FILE" 2>/dev/null | sed -n 's/.*"format": *"\([^"]\+\)".*/\1/p')"
  [[ -z "${IMG_FORMAT:-}" ]] && IMG_FORMAT="raw"
  log "→ Format: $IMG_FORMAT"

  log "B4/6 Resize image theo ổ vật lý (chừa 2GB)"
  if command -v lsblk >/dev/null 2>&1; then
    if lsblk | awk '{print $1}' | grep -q '^vda$'; then DEV_DISK="/dev/vda"; else DEV_DISK="/dev/sda"; fi
    if [[ -b "$DEV_DISK" ]]; then
      DISK_SIZE=$(lsblk -b -d -n -o SIZE "$DEV_DISK")
      DISK_SIZE_GB=$((DISK_SIZE/1024/1024/1024))
      if (( DISK_SIZE_GB > 10 )); then TARGET_SIZE="$((DISK_SIZE_GB - 2))G"; else TARGET_SIZE="${DISK_SIZE_GB}G"; fi
      log "→ Resize lên $TARGET_SIZE (ổ thật: ${DISK_SIZE_GB}GB)"
      qemu-img resize -f "$IMG_FORMAT" "$IMG_FILE" "$TARGET_SIZE" || true
    else
      log "⚠️  Không tìm thấy block device, bỏ qua resize."
    fi
  else
    log "⚠️  lsblk không có, bỏ qua resize."
  fi

  log "B5/6 Mở firewall cho RDP (TCP+UDP :${RDP_PORT})"
  open_ports "$RDP_PORT"
  if ss -lnt | awk '{print $4}' | grep -q ":${RDP_PORT}$"; then
    log "⚠️  Port ${RDP_PORT} đã có tiến trình lắng nghe. Đổi RDP_PORT rồi chạy lại."; exit 1
  fi

  log "B6/6 Khởi động VM (headless)"
  if [[ -e /dev/kvm ]]; then
    ACCEL="-enable-kvm -cpu host,hv_time,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff"
  else
    ACCEL="-accel tcg,thread=multi -cpu max"
  fi
  if qemu-system-x86_64 -help 2>/dev/null | grep -q io_uring; then AIO_MODE="io_uring"; else AIO_MODE="threads"; fi

  set -x
  qemu-system-x86_64 \
    $ACCEL -smp "$VM_CPU" -m "$VM_RAM" \
    -name "$VM_NAME" \
    -rtc base=localtime \
    -drive file="$IMG_FILE",format="$IMG_FORMAT",if=ide,cache=writeback,aio="${AIO_MODE}" \
    -netdev user,id=n1,hostfwd=tcp::${RDP_PORT}-:3389,hostfwd=udp::${RDP_PORT}-:3389 \
    -device e1000,netdev=n1 \
    -usb -device usb-tablet \
    -display none \
    -daemonize
  { set +x; } 2>/dev/null

  sleep 1
  if pgrep -fa "qemu-system-x86_64.*-name $VM_NAME" >/dev/null; then
    log "✅ VM đã chạy nền."
  else
    log "❌ Không thấy tiến trình QEMU. Xem log: $LOG_FILE"; exit 1
  fi

  hr
  log "HOÀN TẤT — Kết nối RDP khi Windows boot xong:"
  echo "  mstsc /v:<IP_VPS>:${RDP_PORT}"
  echo "  Forward: host:${RDP_PORT} (TCP+UDP) → guest:3389"
  echo "  Log: $LOG_FILE  (xem live: tail -f $LOG_FILE)"
  hr
}

main "$@"
