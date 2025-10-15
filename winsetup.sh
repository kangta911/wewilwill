#!/bin/bash
set -Eeuo pipefail

# ====== CONFIG ======
IMG_URL="https://www.dropbox.com/scl/fi/wozij42y4dsj4begyjwj1/10-lite.img?rlkey=lyb704acrmr1k023b81w3jpsk&st=e3b81z4i&dl=1"
IMG_DIR="/var/lib/libvirt/images"
IMG_FILE="$IMG_DIR/10-lite.img"
RDP_PORT="${RDP_PORT:-2025}"     # export RDP_PORT=4000 để đổi nhanh
VM_NAME="${VM_NAME:-win10lite}"
VM_RAM="${VM_RAM:-2048}"         # MB | export VM_RAM=4096 nếu muốn
VM_CPU="${VM_CPU:-2}"            # vCPU | export VM_CPU=4 nếu muốn

# ====== UTILS ======
log() { echo -e "$*"; }

# Đợi lock APT (an toàn, không xóa file lock bừa)
apt_wait_unlock() {
  local timeout="${1:-180}"  # 3 phút
  local waited=0
  local locks=(
    "/var/lib/apt/lists/lock"
    "/var/lib/dpkg/lock"
    "/var/lib/dpkg/lock-frontend"
    "/var/cache/apt/archives/lock"
  )
  while :; do
    local busy=0
    if pgrep -fa 'apt|dpkg|unattended' >/dev/null 2>&1; then
      busy=1
    else
      busy=0
      for f in "${locks[@]}"; do
        [[ -e "$f" ]] && { busy=1; break; }
      done
    fi

    if [[ $busy -eq 0 ]]; then
      break
    fi

    (( waited++ ))
    if (( waited >= timeout )); then
      log "⚠️  Hết thời gian chờ APT (${timeout}s). Thử dừng apt-daily & unattended-upgrades."
      systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
      systemctl kill --kill-who=main --signal=TERM apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
      sleep 5
      waited=0
    else
      sleep 1
    fi
  done
}

apt_safe_install() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt_wait_unlock 60
    dpkg --configure -a >/dev/null 2>&1 || true
    apt_wait_unlock 60
    apt-get update -y || true
    apt_wait_unlock 60

    local pkgs=(qemu-system-x86 qemu-utils wget curl)
    if apt-cache show ufw >/dev/null 2>&1; then pkgs+=(ufw); fi

    local i
    for i in {1..3}; do
      apt_wait_unlock 120
      if apt-get install -y "${pkgs[@]}"; then
        return 0
      fi
      log "⚠️  apt-get install thất bại (lần $i). Thử lại..."
      sleep 5
    done
    log "❌ Cài gói bằng apt-get thất bại sau 3 lần."
    return 1

  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y qemu-kvm qemu-img wget curl || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y qemu-kvm qemu-img wget curl || true
  else
    log "❌ Không tìm thấy apt/dnf/yum để cài gói."
    return 1
  fi
}

open_ports() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" || true
    ufw allow "${port}/udp" || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
    iptables -I INPUT -p udp --dport "$port" -j ACCEPT || true
  fi
  if command -v nft >/dev/null 2>&1; then
    nft add rule inet filter input tcp dport "$port" accept 2>/dev/null || true
    nft add rule inet filter input udp dport "$port" accept 2>/dev/null || true
  fi
}

# ====== PREP ======
if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
$SUDO mkdir -p "$IMG_DIR"
cd "$IMG_DIR"

log "🟢 Chuẩn bị & cài gói cần thiết (chờ APT nếu đang bận)..."
apt_safe_install

# Thử load KVM (nếu host cho phép)
$SUDO modprobe kvm 2>/dev/null || true
$SUDO modprobe kvm-intel 2>/dev/null || $SUDO modprobe kvm-amd 2>/dev/null || true

# ====== IMAGE ======
if [[ ! -f "$IMG_FILE" ]]; then
  log "🟢 Tải image Windows..."
  wget -O "$IMG_FILE" "$IMG_URL"
else
  log "🟢 Image đã tồn tại: $IMG_FILE"
fi

log "🟢 Kiểm tra format image..."
qemu-img info "$IMG_FILE" || true
IMG_FORMAT="$(qemu-img info --output=json "$IMG_FILE" 2>/dev/null | sed -n 's/.*"format": *"\([^"]\+\)".*/\1/p')"
[[ -z "${IMG_FORMAT:-}" ]] && IMG_FORMAT="raw"
log "➡  Format: $IMG_FORMAT"

# ====== RESIZE (theo ổ vật lý, chừa 2GB) ======
if command -v lsblk >/dev/null 2>&1; then
  if lsblk | awk '{print $1}' | grep -q '^vda$'; then DEV_DISK="/dev/vda"; else DEV_DISK="/dev/sda"; fi
  if [[ -b "$DEV_DISK" ]]; then
    DISK_SIZE=$(lsblk -b -d -n -o SIZE "$DEV_DISK")
    DISK_SIZE_GB=$((DISK_SIZE/1024/1024/1024))
    if (( DISK_SIZE_GB > 10 )); then
      TARGET_SIZE="$((DISK_SIZE_GB - 2))G"
    else
      TARGET_SIZE="${DISK_SIZE_GB}G"
    fi
    log "🟢 Resize image lên $TARGET_SIZE (ổ thật: ${DISK_SIZE_GB}GB)..."
    qemu-img resize -f "$IMG_FORMAT" "$IMG_FILE" "$TARGET_SIZE"
  else
    log "⚠️  Không xác định được ổ vật lý, bỏ qua resize."
  fi
else
  log "⚠️  lsblk không khả dụng, bỏ qua resize."
fi

# ====== FIREWALL ======
open_ports "$RDP_PORT"

# ====== RUN ======
log "🟢 Khởi động VM (headless; auto chọn KVM/TCG)..."
if [[ -e /dev/kvm ]]; then
  ACCEL="-enable-kvm -cpu host,hv_time,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff"
  log "➡  Dùng KVM (/dev/kvm có sẵn)."
else
  ACCEL="-accel tcg,thread=multi -cpu max"
  log "➡️  Không có /dev/kvm ⇒ dùng TCG (chậm hơn)."
fi

# Chọn AIO tốt nhất mà QEMU hỗ trợ
if qemu-system-x86_64 -help 2>/dev/null | grep -q io_uring; then
  AIO_MODE="io_uring"
else
  AIO_MODE="threads"
fi

# NIC e1000 để có mạng ngay; image đã bật sẵn RDP + user/pass
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

log "✅ VM đã khởi chạy nền (headless)."
log "🔁 RDP: mstsc /v:<IP_VPS>:${RDP_PORT}"
log "ℹ️  Forward host:${RDP_PORT} (TCP+UDP) -> guest:3389"
