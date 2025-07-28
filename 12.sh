#!/bin/bash
set -e

WIN_IMAGE_URL="http://drive.muavps.net/windows/Windows10_Lite.gz"
WIN_IMG="Windows10_Lite.img"

export DEBIAN_FRONTEND=noninteractive

# Chuẩn bị môi trường (ẩn log)
sudo apt update > /dev/null 2>&1
sudo apt install -y qemu-system-x86 wget gzip > /dev/null 2>&1

mkdir -p ~/win && cd ~/win

# Tải & giải nén image nếu cần (ẩn log)
if [ ! -f "$WIN_IMG" ]; then
    wget -q -O Windows10_Lite.gz "$WIN_IMAGE_URL"
    gunzip -c Windows10_Lite.gz > "$WIN_IMG"
    rm -f Windows10_Lite.gz
fi

# Dò dung lượng VPS & resize image
ROOT_FREE_GB=$(df -BG . | awk 'NR==2{gsub("G","",$4); print $4}')
TARGET_SIZE=$((ROOT_FREE_GB>10 ? ROOT_FREE_GB-2 : 12))
qemu-img resize "$WIN_IMG" ${TARGET_SIZE}G > /dev/null 2>&1 || {
    echo "❌ Không thể resize file image (ổ cứng VPS quá nhỏ hoặc file lỗi)!"
    exit 1
}

# Port mặc định 2025
RDP_PORT=2025

# RAM/CPU tối ưu (ẩn log)
TOTAL_CPU=$(nproc)
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
QEMU_CPUS=$(( TOTAL_CPU > 2 ? 2 : TOTAL_CPU ))
QEMU_RAM=$(( TOTAL_RAM > 2048 ? TOTAL_RAM - 1024 : TOTAL_RAM - 512 ))
[ $QEMU_RAM -lt 1024 ] && QEMU_RAM=1024

pkill -f "qemu-system-x86_64.*$WIN_IMG" 2>/dev/null || true

IP=$(curl -s ifconfig.me)
echo ""
echo "⏳ Đang cài đặt Windows: 100%"
sleep 1
echo "✅ Hoàn tất! Windows đã boot và mở RDP tại $IP:$RDP_PORT"
echo "🔑 Đăng nhập: Administrator / Datnguyentv.com"
echo ""
echo "💡 Để dùng hết dung lượng VPS, vào Windows → Disk Management → chuột phải ổ C → Extend Volume..."
echo "Dùng Remote Desktop (RDP) truy cập sau 5–10 phút!"

# Khởi động QEMU, ẩn log
nohup qemu-system-x86_64 \
  -enable-kvm \
  -m "$QEMU_RAM" \
  -smp "$QEMU_CPUS" \
  -cpu host \
  -drive file="$WIN_IMG",format=raw \
  -net nic -net user,hostfwd=tcp::${RDP_PORT}-:3389 \
  -nographic > qemu.log 2>&1 &

sleep 5

QEMU_PID=$(pgrep -f "qemu-system-x86_64.*$WIN_IMG" | head -n 1)
if [ -z "$QEMU_PID" ] || ! kill -0 $QEMU_PID 2>/dev/null; then
    echo "❌ QEMU không khởi động được! Có thể thiếu RAM hoặc VPS quá yếu."
    exit 1
fi

sleep 20

if grep -qi "cannot allocate memory" qemu.log 2>/dev/null; then
    echo "❌ QEMU lỗi: Thiếu RAM! Vui lòng tăng RAM VPS hoặc giảm QEMU_RAM."
    exit 1
fi
if grep -qi "No bootable device" qemu.log 2>/dev/null; then
    echo "❌ QEMU lỗi: Không tìm thấy thiết bị boot! Kiểm tra lại file image."
    exit 1
fi

echo "Bạn có thể RDP sau 5–10 phút!"
echo "Vào Windows, Extend Volume ổ C để tận dụng toàn bộ dung lượng VPS!"

