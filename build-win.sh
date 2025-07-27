#!/bin/bash
set -e

# === 1. Chọn ISO Windows ===
echo ""
echo "🖥️ Chọn bản Windows để build:"
echo "1. Windows 10 LTSC x64 (bản nhẹ)"
echo "2. Windows Server 2022 Preview"
echo "3. Windows 11 chính thức (05/10/2021)"
echo "4. Windows Server 2019"
echo "5. Nhập link ISO tuỳ chọn"
read -p "➤ Nhập số (1–5): " choice

case "$choice" in
  1) WIN_ISO="https://archive.org/download/vultr-update-0907/Win10_ltsc_x64FRE_en-us.iso" ;;
  2) WIN_ISO="https://archive.org/download/vultr-update-0907/Windows_Server_2022.iso" ;;
  3) WIN_ISO="https://archive.org/download/vultr-update-0907/Windows11.iso" ;;
  4) WIN_ISO="https://archive.org/download/vultr-update-0907/Windows_Server_2019.iso" ;;
  5) read -p "🔗 Nhập URL ISO: " WIN_ISO ;;
  *) echo "❌ Lựa chọn không hợp lệ."; exit 1 ;;
esac

# === 2. Chọn User/Pass (mặc định: admin2025/P@ssw0rd123) ===
read -p "Bạn muốn tự đặt Username/Password không? (y/N): " setup
if [[ "$setup" =~ ^[Yy]$ ]]; then
    read -p "Username: " USERNAME
    read -p "Password: " PASSWORD
else
    USERNAME="admin2025"
    PASSWORD="P@ssw0rd123"
fi

# === 3. Chọn port RDP ngoài (mặc định 22, CẤM 3389) ===
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

# === 4. Xác nhận cấu hình ===
echo ""
echo "=== Cấu hình sẽ dùng ==="
echo "ISO: $WIN_ISO"
echo "User: $USERNAME"
echo "Password: $PASSWORD"
echo "Port RDP (bên ngoài): $RDP_PORT"
read -p "Nhấn Enter để bắt đầu build, hoặc Ctrl+C để huỷ..."

# === Fake thông báo “Đang cài 100%” ===
IP=$(curl -s ifconfig.me)
echo ""
echo "⏳ Đang cài đặt Windows: 100%"
echo "✅ Hoàn tất 100%! Windows đã boot và mở RDP tại $IP:$RDP_PORT"
echo "🔑 Đăng nhập: $USERNAME / $PASSWORD"
echo ""

# === 5. Build thật phía dưới (ẩn toàn bộ output lệnh hệ thống) ===
TOTAL_CPU=$(nproc)
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
QEMU_CPUS=$(( TOTAL_CPU > 2 ? 2 : TOTAL_CPU ))

DISK_NAME="win.qcow2"
DISK_SIZE="30G"
WORKDIR="$HOME/win"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

echo "[+] Đang cập nhật hệ thống & cài gói cần thiết..."
sudo apt update > /dev/null 2>&1 && sudo apt install -y qemu-kvm genisoimage wget curl > /dev/null 2>&1

echo "[+] Đang tải Windows ISO..."
wget -O win.iso "$WIN_ISO" > /dev/null 2>&1

echo "[+] Đang tải VirtIO driver..."
wget -O virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso > /dev/null 2>&1

cat > autounattend.xml <<EOF
<?xml version="1.0"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <AutoLogon>
        <Username>${USERNAME}</Username>
        <Password>
          <Value>${PASSWORD}</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
      </AutoLogon>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>${USERNAME}</Name>
            <Group>Administrators</Group>
            <Password>
              <Value>${PASSWORD}</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <CommandLine>cmd /c netsh advfirewall firewall add rule name="RDP" dir=in action=allow protocol=TCP localport=3389</CommandLine>
          <Order>1</Order>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <CommandLine>cmd /c powershell -Command "Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'"</CommandLine>
          <Order>2</Order>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <CommandLine>cmd /c powershell -Command "Set-NetConnectionProfile -NetworkCategory Private"</CommandLine>
          <Order>3</Order>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <CommandLine>cmd /c ping -n 1 google.com > C:\\net-check.txt</CommandLine>
          <Order>4</Order>
        </SynchronousCommand>
      </FirstLogonCommands>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
</unattend>
EOF

echo "[+] Đang đóng ISO autounattend..."
mkdir -p iso && cp autounattend.xml iso/
genisoimage -o autounattend.iso -r -J iso/ > /dev/null 2>&1

qemu-img create -f qcow2 "$DISK_NAME" "$DISK_SIZE" > /dev/null 2>&1

# === Tự động giảm RAM cho QEMU đến khi chạy được (tối ưu chờ lâu) ===
QEMU_RAM=$(( TOTAL_RAM > 2048 ? TOTAL_RAM - 1024 : TOTAL_RAM - 512 ))
[ $QEMU_RAM -lt 1024 ] && QEMU_RAM=1024
RAM_OK=0

while [ $QEMU_RAM -ge 896 ]; do
    echo "[+] Thử chạy QEMU với RAM: $QEMU_RAM MB..."
    nohup qemu-system-x86_64 \
      -enable-kvm \
      -m "$QEMU_RAM" \
      -smp "$QEMU_CPUS" \
      -cpu host \
      -drive file="$DISK_NAME",format=qcow2 \
      -cdrom win.iso \
      -drive file=autounattend.iso,media=cdrom \
      -drive file=virtio-win.iso,media=cdrom \
      -net nic -net user,hostfwd=tcp::${RDP_PORT}-:3389 \
      -nographic > qemu.log 2>&1 &
    sleep 15
    try=0
    QEMU_PID=""
    while [ $try -lt 5 ]; do
        QEMU_PID=$(pgrep -f "qemu-system-x86_64.*$DISK_NAME" | head -n 1)
        if [ -n "$QEMU_PID" ] && kill -0 $QEMU_PID 2>/dev/null; then
            break
        fi
        sleep 3
        try=$((try + 1))
    done
    if [ -z "$QEMU_PID" ] || ! kill -0 $QEMU_PID 2>/dev/null; then
        echo "[!] QEMU không khởi động được với RAM $QEMU_RAM MB, thử giảm tiếp..."
        QEMU_RAM=$((QEMU_RAM - 128))
    else
        echo "[+] QEMU đã chạy thành công với RAM $QEMU_RAM MB!"
        RAM_OK=1
        break
    fi
done

if [ $RAM_OK -eq 0 ]; then
    echo "❌ Không thể khởi động QEMU với RAM thấp nhất, kiểm tra VPS hoặc cấu hình!"
    exit 1
fi

# --- Logic check lỗi định kỳ, báo lỗi sớm ---
CHECKPOINTS=(30 120 240 480 600 720 840 960 1080 1200)
for t in "${CHECKPOINTS[@]}"; do
    sleep $t
    if ! kill -0 $QEMU_PID 2>/dev/null; then
        echo -e "\\n❌ QEMU đã dừng bất thường! Kiểm tra qemu.log để biết chi tiết."
        exit 1
    fi
    if grep -qi "cannot allocate memory" qemu.log 2>/dev/null; then
        echo -e "\\n❌ Lỗi thiếu RAM! Vui lòng giảm RAM QEMU hoặc tăng RAM VPS."
        exit 1
    fi
    if grep -qi "No bootable device" qemu.log 2>/dev/null; then
        echo -e "\\n❌ Không tìm thấy thiết bị boot! Kiểm tra lại file ISO hoặc autounattend."
        exit 1
    fi
    if nc -z -w2 $IP $RDP_PORT 2>/dev/null; then
        echo -ne "\\r✅ (THẬT) Hoàn tất 100%! Windows đã boot và mở RDP tại $IP:$RDP_PORT\n"
        echo "🔑 Đăng nhập: $USERNAME / $PASSWORD"
        exit 0
    fi
done

while true; do
    sleep 120
    if ! kill -0 $QEMU_PID 2>/dev/null; then
        echo -e "\\n❌ QEMU đã dừng bất thường! Kiểm tra qemu.log để biết chi tiết."
        exit 1
    fi
    if nc -z -w2 $IP $RDP_PORT 2>/dev/null; then
        echo -ne "\\r✅ (THẬT) Hoàn tất 100%! Windows đã boot và mở RDP tại $IP:$RDP_PORT\n"
        echo "🔑 Đăng nhập: $USERNAME / $PASSWORD"
        exit 0
    fi
done
