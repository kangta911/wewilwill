#!/bin/bash
set -e

WIN_IMAGE_URL="http://drive.muavps.net/windows/Windows10_Lite.gz"
WIN_GZ="Windows10_Lite.gz"
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

# ======= 2. Thông báo auto ghi đè =========
echo -e "\nỔ đĩa mặc định sẽ ghi Win: $DEVICE"
lsblk
echo -e "\n⛔️ Đã tự động xác nhận: SẼ GHI ĐÈ toàn bộ $DEVICE, xoá sạch Ubuntu!\n"

# ======= 3. Tải file + giả lập % ======
echo -e "⏳ Đang tải Windows image..."
wget -O "$WIN_GZ" "$WIN_IMAGE_URL" 2>&1 | grep --line-buffered -o '[0-9]*%' | uniq &
WGET_PID=$!

# Fake progress bar song song
(
    for ((i=1; i<=100; i+=2)); do
        printf "\r[%-50s] %d%%" "$(printf '#%.0s' $(seq 1 $((i/2))))" "$i"
        sleep 0.35
        [ -e /tmp/winimg_done ] && break
    done
    printf "\r[%-50s] 100%%\n" "##################################################"
) &
BAR_PID=$!

wait $WGET_PID || { echo; echo "❌ Lỗi tải file!"; kill $BAR_PID 2>/dev/null; exit 1; }
touch /tmp/winimg_done
wait $BAR_PID 2>/dev/null

echo -e "\n⏳ Đang giải nén Windows image..."
gunzip -c "$WIN_GZ" > Windows10_Lite.img || { echo "❌ Lỗi giải nén!"; exit 1; }
rm -f "$WIN_GZ"

# ======= 4. Ghi image lên disk ==========
echo -e "\n⏳ Đang ghi image Win lên ổ đĩa $DEVICE (toàn bộ Ubuntu sẽ bị xoá!)..."
sleep 2

(
    for ((p=90; p<100; p++)); do
        printf "\r[%-50s] %d%%" "$(printf '#%.0s' $(seq 1 $((p/2))))" "$p"
        sleep 0.5
    done
) &

dd if=Windows10_Lite.img of=$DEVICE bs=64K status=progress conv=fsync || { echo "❌ Lỗi ghi image lên ổ đĩa!"; exit 1; }
sync
kill $! 2>/dev/null
printf "\r[%-50s] 100%%\n" "##################################################"
echo

# ========== 5. Kết thúc + hướng dẫn ==========
echo -e "\n✅ Cài đặt Windows thành công! Ổ VPS đã bị ghi đè, Ubuntu sẽ không boot lại.\n"
echo "🔑 Remote Desktop: IP <vps-ip> | Port: $RDP_PORT"
echo "  User: Administrator | Pass: Datnguyentv.com"
echo "💡 Sau khi reboot, chờ vài phút, truy cập RDP như trên!"
echo "⛔️ VPS sẽ tự động mất SSH, bạn cần reboot bằng dashboard hoặc web console!"
echo

sleep 3
echo "Đang reboot VPS..."
reboot
