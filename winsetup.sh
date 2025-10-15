#!/bin/bash
set -Eeuo pipefail

# ====== CONFIG ======
IMG_URL="https://www.dropbox.com/scl/fi/wozij42y4dsj4begyjwj1/10-lite.img?rlkey=lyb704acrmr1k023b81w3jpsk&st=e3b81z4i&dl=1"
IMG_DIR="/var/lib/libvirt/images"
IMG_FILE="$IMG_DIR/10-lite.img"
RDP_PORT=2025           # host:2025 -> guest:3389
VM_NAME="win10lite"
VM_RAM=2048             # MB
VM_CPU=2

# ====== HELPERS (chờ APT nhả lock, không xóa file lock) ======
apt_wait_unlock() {
  local timeout="${1:-180}" waited=0
  local locks=(
    /var/lib/apt/lists/lock
    /var/lib/dpkg/lock
    /var/lib/dpkg/lock-frontend
    /var/cache/apt/archives/lock
  )
  while :; do
    local busy=0
    pgrep -fa 'apt|dpkg|unattended' >/dev/null 2>&1 && busy=1
    if (( !busy )); then
      for f in "${locks[@]}"; do [[ -e "$f" ]] && { busy=1; break; }; done
    fi
    (( !busy )) && break
    (( waited++ ))
    if (( waited>=timeout )); then
      # dừng service apt tự động rồi chờ tiếp
      systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
      systemctl kill --kill-who=main --signal=TERM apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
      sleep 5; waited=0
    else
      sleep 1
    fi
  done
}

# ====== PREP ======
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
$SUDO mkdir -p "$IMG_DIR"
cd "$IMG_DIR"

echo "🟢 Cài gói cần thiết..."
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  # chờ APT sẵn sàng, cấu hình dpkg nếu cần
  apt_wait_unlock 120
  $SUDO dpkg --configure -a || true

  # retry update+install tối đa 3 lần
  for i in 1 2 3; do
    apt_wait_unlock 120
    $SUDO apt-get update -y && \
    $SUDO apt-get install -y qemu-system-x86 qemu-utils wget curl ufw && break
    echo "⚠️ apt-get bị bận/lỗi (lần $i) — chờ và thử lại..."
    sleep 5
    # dừng các service apt tự động rồi thử lại vòng sau
    $SUDO systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
  done
elif command -v dnf >/dev/null 2>&1; then
  $SUDO dnf install -y qemu-kvm qemu-img wget curl || true
elif command -v yum >/dev/null 2>&1; then
  $SUDO yum install -y qemu-kvm qemu-img wget curl || true
fi

# Thử load KVM (nếu host cho phép)
$SUDO modprobe kvm 2>/dev/null || true
$SUDO modprobe kvm-intel 2>/dev/null || $SUDO modprobe kvm-amd 2>/dev/null || true

# ====== IMAGE ======
if [ ! -f "$IMG_FILE" ]; then
  echo "🟢 Tải image Windows..."
  wget -O "$IMG_FILE" "$IMG_URL"
else
  echo "🟢 Image đã tồn tại: $IMG_FILE"
fi

echo "🟢 Kiểm tra format image..."
qemu-img info "$IMG_FILE" || true
IMG_FORMAT="$(qemu-img info --output=json "$IMG_FILE" 2>/dev/null | sed -n 's/.*\"format\": *\"\([^\"]\+\)\".*/\1/p')"
[ -z "${IMG_FORMAT:-}" ] && IMG_FORMAT="raw"
echo "➡  Format: $IMG_FORMAT"

# ====== RESIZE (theo ổ vật lý, chừa 2GB) ======
if lsblk | grep -q '^vda'; then DEV_DISK="/dev/vda"; else DEV_DISK="/dev/sda"; fi
if [ -b "$DEV_DISK" ]; then
  DISK_SIZE=$(lsblk -b -d -n -o SIZE "$DEV_DISK")
  DISK_SIZE_GB=$((DISK_SIZE/1024/1024/1024))
  if [ $DISK_SIZE_GB -gt 10 ]; then
    TARGET_SIZE="$((DISK_SIZE_GB - 2))G"
  else
    TARGET_SIZE="${DISK_SIZE_GB}G"
  fi
  echo "🟢 Resize image lên $TARGET_SIZE (ổ thật: ${DISK_SIZE_GB}GB)..."
  qemu-img resize -f "$IMG_FORMAT" "$IMG_FILE" "$TARGET_SIZE"
else
  echo "⚠️  Không xác định được ổ vật lý, bỏ qua resize."
fi

# ====== FIREWALL & PORTS ======
# Mở port host cho RDP
if command -v ufw >/dev/null 2>&1; then
  $SUDO ufw allow ${RDP_PORT}/tcp || true
fi
if command -v iptables >/dev/null 2>&1; then
  $SUDO iptables -I INPUT -p tcp --dport "$RDP_PORT" -j ACCEPT || true
fi

# Kiểm tra xung đột port RDP
if ss -lnt | awk '{print $4}' | grep -q ":${RDP_PORT}$"; then
  echo "✅ Host đang lắng nghe port RDP ${RDP_PORT} (sẽ dùng cho forward)."
fi

# ====== RUN ======
echo "🟢 Khởi động VM (auto chọn KVM/TCG)..."
if [ -e /dev/kvm ]; then
  ACCEL="-enable-kvm -cpu host"
  echo "➡  Dùng KVM (/dev/kvm có sẵn)."
else
  ACCEL="-accel tcg,thread=multi -cpu max"
  echo "➡  Không có /dev/kvm ⇒ dùng TCG (chậm hơn)."
fi

# Headless, NO VNC
qemu-system-x86_64 \
  $ACCEL -smp "$VM_CPU" -m "$VM_RAM" \
  -name "$VM_NAME" \
  -rtc base=localtime \
  -drive file="$IMG_FILE",format="$IMG_FORMAT",if=ide,cache=none,aio=threads \
  -netdev user,id=n1,hostfwd=tcp::${RDP_PORT}-:3389 \
  -device e1000,netdev=n1 \
  -usb -device usb-tablet \
  -display none \
  -daemonize

echo "✅ VM đã khởi chạy nền."
echo "🔁 RDP forward: host:${RDP_PORT} -> guest:3389"
echo "ℹ️  RDP:  mstsc /v:<IP_HOST>:${RDP_PORT}"
