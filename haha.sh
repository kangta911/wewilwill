#!/bin/bash
set -e

IMG_URL="http://drive.muavps.net/windows/windows10LTSB.gz"
IMG_GZ="windows10LTSB.gz"
IMG_RAW="windows10LTSB.img"
RDP_PORT=2025 # bạn có thể cho phép người dùng nhập nếu thích

DEVICE="/dev/vda"  # đa số VPS DO sẽ là vda, có thể cần kiểm tra lại

echo "=== Cảnh báo: Toàn bộ dữ liệu ổ $DEVICE sẽ bị GHI ĐÈ bằng Windows ==="
echo "== Đang chuẩn bị tải & ghi image Windows, thao tác tự động 100% =="
sleep 2

# 1. Cài công cụ cần thiết
sudo apt update -y > /dev/null 2>&1
sudo apt install -y wget gzip curl > /dev/null 2>&1

cd /root || cd ~

# 2. Tải và giải nén image nếu chưa có
if [ ! -f "$IMG_RAW" ]; then
  echo "[+] Đang tải image Windows..."
  wget -O "$IMG_GZ" "$IMG_URL"
  echo "[+] Đang giải nén..."
  gunzip -c "$IMG_GZ" > "$IMG_RAW"
  rm -f "$IMG_GZ"
fi

# 3. Xác định thiết bị ghi đè, tự động tìm thiết bị root lớn nhất (nếu cần)
# DEVICE=$(lsblk -ndo NAME,SIZE,TYPE | awk '$3=="disk"{print "/dev/"$1,$2}' | sort -k2 -rh | head -n1 | awk '{print $1}')

# 4. Ghi đè image lên ổ cứng
echo "[+] Ghi đè Windows lên $DEVICE (toàn bộ Ubuntu sẽ bị xoá!)"
sleep 3
sync
dd if="$IMG_RAW" of="$DEVICE" bs=100M status=progress conv=fsync

sync

echo "[+] Đã ghi xong Windows image. VPS sẽ shutdown (tự động)."
echo "== Sau khi máy khởi động lại (có thể 2–5 phút), dùng Remote Desktop kết nối =="
IP=$(curl -s ifconfig.me)
echo "▶ IP: $IP"
echo "▶ PORT: $RDP_PORT"
echo "▶ User: Administrator"
echo "▶ Pass: Datnguyentv.com"
echo ""
echo "✅ Nếu image chuẩn, khi boot lại sẽ nhận full ổ cứng (extend trong Windows nếu cần), có mạng, vào RDP bình thường."
echo "== Tắt máy trong 10 giây..."
sleep 10
poweroff
