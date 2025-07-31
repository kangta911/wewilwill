#!/bin/bash
set -e

WIN_IMAGE_URL="https://www.dropbox.com/scl/fi/wozij42y4dsj4begyjwj1/10-lite.img?rlkey=lyb704acrmr1k023b81w3jpsk&st=e3b81z4i&dl=1"
WIN_IMG="10-lite.img"
DEVICE="/dev/vda"

# ======== 1. Chọn port RDP =========
while true; do
    read -p "Nhập port RDP muốn dùng (mặc định: 2025, KHÔNG ĐƯỢC 3389/22): " RDP_PORT
    RDP_PORT=${RDP_PORT:-2025}
    if [[ "$RDP_PORT" == "3389" || "$RDP_PORT" == "22" ]]; then
        echo "❌ Không được chọn port 3389 hoặc 22! Thử lại."
    elif [[ "$RDP_PORT" =~ ^[0-9]{2,5}$ ]] && [ "$RDP_PORT" -ge 1 ] && [ "$RDP_PORT" -le 65535 ]; then
        break
    else
        echo "❌ Port không hợp lệ, thử lại."
    fi
done

# ======= 2. Cảnh báo ghi đè =========
echo -e "\n💥 SẼ GHI ĐÈ TOÀN BỘ $DEVICE! Ubuntu sẽ bị xoá."
lsblk
echo -e "⛔️ Đã xác nhận: TIẾN HÀNH xoá đĩa và cài Windows.\n"
sleep 3

# ======= 3. Tải file từ Dropbox =======
echo -e "⏳ Đang tải file Windows image từ Dropbox..."
curl -L -o "$WIN_IMG" "$WIN_IMAGE_URL" || {
    echo "❌ Lỗi khi tải file từ Dropbox!"
    exit 1
}

# ======= 4. Ghi image lên đĩa ==========
echo -e "\n⏳ Đang ghi image lên đĩa $DEVICE..."
sleep 2

(
    for ((p=90; p<=99; p++)); do
        printf "\r[%-50s] %d%%" "$(printf '#%.0s' $(seq 1 $((p/2))))" "$p"
        sleep 0.4
    done
) &

dd if="$WIN_IMG" of="$DEVICE" bs=64K status=progress conv=fsync || {
    echo "❌ Lỗi khi ghi image!"
    exit 1
}
sync
kill $! 2>/dev/null
printf "\r[%-50s] 100%%\n" "##################################################"
echo

# ========== 5. Kết thúc ==========
echo -e "\n✅ Cài Windows thành công!"
echo "🔑 Remote Desktop: IP <vps-ip> | Port: $RDP_PORT"
echo "  User: admincp | Pass: kangclip.com"
echo "💡 Sau reboot, chờ vài phút rồi kết nối RDP!"
echo "⛔️ SSH sẽ mất kết nối. Dùng console để reboot nếu chưa tự động."
echo

sleep 3
echo "Đang reboot VPS..."
reboot
