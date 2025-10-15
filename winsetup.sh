#!/bin/bash
set -Eeuo pipefail

# ====== CONFIG ======
IMG_URL="https://www.dropbox.com/scl/fi/wozij42y4dsj4begyjwj1/10-lite.img?rlkey=lyb704acrmr1k023b81w3jpsk&st=e3b81z4i&dl=1"
IMG_DIR="/var/lib/libvirt/images"
IMG_FILE="$IMG_DIR/10-lite.img"
RDP_PORT=2025           # host:2025 -> guest:3389
VM_NAME="win10lite"
VM_RAM=2048             # MB (tăng chút cho Windows mượt hơn)
VM_CPU=2

# ====== PREP ======
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
$SUDO mkdir -p "$IMG_DIR"
cd "$IMG_DIR"

echo "🟢 Cài gói cần thiết..."
if command -v apt-get >/dev/null 2>&1; then
  $SUDO apt-get update -y
  $SUDO apt-get install -y qemu-system-x86 qemu-utils wget curl ufw || true
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
IMG_FORMAT="$(qemu-img info --output=json "$IMG_FILE" 2>/dev/null | sed -n 's/.*"format": *"\([^"]\+\)".*/\1/p')"
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

# Headless, KHÔNG VNC
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
echo "ℹ️  Dùng RDP:  mstsc /v:<IP_HOST>:${RDP_PORT}"
