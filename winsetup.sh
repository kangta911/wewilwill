#!/bin/bash
set -Eeuo pipefail

# ====== CONFIG ======
IMG_URL="https://www.dropbox.com/scl/fi/wozij42y4dsj4begyjwj1/10-lite.img?rlkey=lyb704acrmr1k023b81w3jpsk&st=e3b81z4i&dl=1"
IMG_DIR="/var/lib/libvirt/images"
IMG_FILE="$IMG_DIR/10-lite.img"
RDP_PORT=2025
VM_RAM=1024        # MB
VM_CPU=2

# ====== PREP ======
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
$SUDO mkdir -p "$IMG_DIR"
cd "$IMG_DIR"

echo "🟢 Cài gói cần thiết..."
$SUDO apt-get update -y
$SUDO apt-get install -y qemu-system-x86 qemu-utils wget curl

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
# Lấy format từ JSON, fallback = raw
IMG_FORMAT="$(qemu-img info --output=json "$IMG_FILE" 2>/dev/null | sed -n 's/.*"format": *"\([^"]\+\)".*/\1/p')"
[ -z "${IMG_FORMAT:-}" ] && IMG_FORMAT="raw"
echo "➡  Format: $IMG_FORMAT"

# ====== RESIZE ======
# Tự phát hiện disk vật lý để chọn dung lượng target (trừ 2GB cho an toàn)
if lsblk | grep -q '^vda'; then DEV_DISK="/dev/vda"; else DEV_DISK="/dev/sda"; fi
DISK_SIZE=$(lsblk -b -d -n -o SIZE "$DEV_DISK")
DISK_SIZE_GB=$((DISK_SIZE/1024/1024/1024))
if [ $DISK_SIZE_GB -gt 10 ]; then
  TARGET_SIZE="$((DISK_SIZE_GB - 2))G"
else
  TARGET_SIZE="${DISK_SIZE_GB}G"
fi

echo "🟢 Resize image lên $TARGET_SIZE (ổ thật: ${DISK_SIZE_GB}GB)..."
qemu-img resize -f "$IMG_FORMAT" "$IMG_FILE" "$TARGET_SIZE"

# ====== NETWORK / FORWARD RDP ======
# Mở port RDP host (nếu có iptables, không bắt buộc)
if command -v iptables >/dev/null 2>&1; then
  $SUDO iptables -I INPUT -p tcp --dport "$RDP_PORT" -j ACCEPT || true
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

# Dùng disk interface IDE để Windows nhận driver sẵn (tránh virtio nếu chưa có ISO driver)
# NIC e1000 để có mạng ngay; NAT forward host:$RDP_PORT -> guest:3389
exec qemu-system-x86_64 \
  $ACCEL -smp "$VM_CPU" -m "$VM_RAM" \
  -drive file="$IMG_FILE",format="$IMG_FORMAT",if=ide,cache=none,aio=threads \
  -netdev user,id=n1,hostfwd=tcp::${RDP_PORT}-:3389 \
  -device e1000,netdev=n1 \
  -display none -serial mon:stdio
