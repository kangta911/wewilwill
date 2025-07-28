#!/bin/bash
set -e

WIN_IMAGE_URL="http://drive.muavps.net/windows/Windows10_Lite.gz"
WIN_IMG="Windows10_Lite.img"

# 1. Chọn port
while true; do
    read -p "Nhập port RDP ngoài muốn sử dụng (mặc định: 22, KHÔNG ĐƯỢC chọn 3389): " RDP_PORT
    RDP_PORT=${RDP_PORT:-22}
    if [[ "$RDP_PORT" == "3389" ]]; then
        echo "❌ Không được chọn port 3389! Vui lòng chọn port khác."
    elif [[ "$RDP_PORT" =~ ^[0-9]{2,5}$ ]] && [ "$RDP_PORT" -ge 1 ] && [ "$RDP_PORT" -le 65535 ]; then
        break
    else
        echo "❌ Port không hợp lệ, thử lại."
    fi
done

# 2. Chuẩn bị môi trường
sudo apt update && sudo apt install -y qemu-system-x86 wget gzip

mkdir -p ~/win && cd ~/win

# 3. Download nếu chưa có image đã giải nén
if [ ! -f "$WIN_IMG" ]; then
    echo "[+] Đang tải và giải nén Windows image, chờ xíu..."
    wget -O Windows10_Lite.gz "$WIN_IMAGE_URL"
    gunzip -c Windows10_Lite.gz > "$WIN_IMG"
    rm -f Windows10_Lite.gz
else
    echo "[+] Đã có $WIN_IMG, bỏ qua bước tải."
fi

# 4. Tự tính RAM/CPU tối ưu
TOTAL_CPU=$(nproc)
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
QEMU_CPUS=$(( TOTAL_CPU > 2 ? 2 : TOTAL_CPU ))
QEMU_RAM=$(( TOTAL_RAM > 2048 ? TOTAL_RAM - 1024 : TOTAL_RAM - 512 ))
[ $QEMU_RAM -lt 1024 ] && QEMU_RAM=1024

# 5. Chạy QEMU (single run, không lặp giảm RAM)
echo "[+] Đang boot Windows, chờ vài phút rồi RDP!"

nohup qemu-system-x86_64 \
  -enable-kvm \
  -m "$QEMU_RAM" \
  -smp "$QEMU_CPUS" \
  -cpu host \
  -drive file="$WIN_IMG",format=raw \
  -net nic -net user,hostfwd=tcp::${RDP_PORT}-:3389 \
  -nographic > qemu.log 2>&1 &

sleep 5

IP=$(curl -s ifconfig.me)
echo ""
echo "✅ Windows đã boot xong. Dùng Remote Desktop kết nối:"
echo "▶ IP: $IP"
echo "▶ PORT: $RDP_PORT"
echo "▶ User: Administrator"
echo "▶ Pass: Datnguyentv.com"
echo ""
echo "Đợi ~5–10 phút (boot lần đầu), rồi dùng RDP truy cập nhé!"
