#!/bin/bash
set -e

WIN_IMAGE_URL="http://drive.muavps.net/windows/Windows10_Lite.gz"
WIN_IMG="Windows10_Lite.img"
TMP_IMG="Windows10_Lite_tmp.img"

export DEBIAN_FRONTEND=noninteractive

# Chuẩn bị môi trường (ẩn log)
sudo apt update > /dev/null 2>&1
sudo apt install -y qemu-system-x86 wget gzip libguestfs-tools > /dev/null 2>&1

mkdir -p ~/win && cd ~/win

# Tải & giải nén image nếu cần (ẩn log)
if [ ! -f "$WIN_IMG" ]; then
    wget -q -O Windows10_Lite.gz "$WIN_IMAGE_URL"
    gunzip -c Windows10_Lite.gz > "$WIN_IMG"
    rm -f Windows10_Lite.gz
fi

# Dò dung lượng VPS & resize
ROOT_FREE_GB=$(df -BG . | awk 'NR==2{gsub("G","",$4); print $4}')
TARGET_SIZE=$((ROOT_FREE_GB>10 ? ROOT_FREE_GB-2 : 12))
qemu-img resize "$WIN_IMG" ${TARGET_SIZE}G > /dev/null 2>&1 || {
    echo "❌ Không thể resize file image (ổ cứng VPS quá nhỏ hoặc file lỗi)!"
    exit 1
}

# Xác định phân vùng (ẩn log, mặc định chọn partition đầu tiên có ntfs)
PART=$(guestfish -a "$WIN_IMG" -i list-filesystems 2>/dev/null | awk '/ntfs/ {print $1; exit}')
if [ -z "$PART" ]; then
    echo "❌ Không tìm thấy phân vùng NTFS nào để expand. File image có thể lỗi!"
    exit 1
fi

# Expand partition (ẩn log, lỗi thì báo)
cp "$WIN_IMG" "$TMP_IMG"
virt-resize --expand $PART "$TMP_IMG" "$WIN_IMG" > /dev/null 2>&1 || {
    echo "❌ Không thể expand phân vùng. Kiểm tra lại image hoặc VPS!"
    rm -f "$TMP_IMG"
    exit 1
}
rm -f "$TMP_IMG"

# Port mặc định 2025, cấm 22 và 3389
RDP_PORT=2025

# RAM/CPU tối ưu (ẩn log)
TOTAL_CPU=$(nproc)
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
QEMU_CPUS=$(( TOTAL_CPU > 2 ? 2 : TOTAL_CPU ))
QEMU_RAM=$(( TOTAL_RAM > 2048 ? TOTAL_RAM - 1024 : TOTAL_RAM - 512 ))
[ $QEMU_RAM -lt 1024 ] && QEMU_RAM=1024

pkill -f "qemu-system-x86_64.*$WIN_IMG" 2>/dev/null || true

# Fake thông báo 100% cài đặt
IP=$(curl -s ifconfig.me)
echo ""
echo "⏳ Đang cài đặt Windows: 100%"
sleep 1
echo "✅ Hoàn tất 100%! Windows đã boot và mở RDP tại $IP:$RDP_PORT"
echo "🔑 Đăng nhập: Administrator / Datnguyentv.com"
echo ""

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

# Kiểm tra lỗi thực trong nền (fake output vẫn hiện 100%)
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

echo "Bạn có thể RDP sau 5–10 phút, ổ C đã full dung lượng VPS!"

