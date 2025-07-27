#!/bin/bash
set -e

# Phát hiện số CPU thực tế
TOTAL_CPU=$(nproc)
# Phát hiện tổng RAM khả dụng (MB)
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
# Để lại 512MB cho hệ điều hành, lấy max cho QEMU
QEMU_RAM=$(( TOTAL_RAM > 2048 ? TOTAL_RAM - 1024 : TOTAL_RAM - 512 ))
[ $QEMU_RAM -lt 1024 ] && QEMU_RAM=1024      # Win cài được tối thiểu 1GB

# Chọn số CPU cho QEMU (ít nhất 1, tối đa bằng thực tế VPS)
QEMU_CPUS=$(( TOTAL_CPU > 2 ? 2 : TOTAL_CPU ))

USERNAME="admin25"
PASSWORD="P@ssw0rd123"
DISK_NAME="win.qcow2"
DISK_SIZE="30G"
RDP_PORT=3389
WORKDIR="$HOME/win"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

echo "[+] Cấu hình tự động:"
echo "  Số CPU QEMU:  $QEMU_CPUS (VPS thực tế: $TOTAL_CPU)"
echo "  RAM QEMU:     $QEMU_RAM MB (VPS thực tế: $TOTAL_RAM MB)"

sudo apt update && sudo apt install -y qemu-kvm genisoimage wget curl

echo ""
echo "🖥️ Chọn bản Windows để build:"
echo "1. Windows 10 LTSC x64 (bản nhẹ)"
echo "2. Windows Server 2022 Preview"
echo "3. Windows 11 chính thức (05/10/2021)"
echo "4. Windows 10 x64 đầy đủ"
echo "5. Windows Server 2016"
echo "6. Windows Server 2019"
echo "7. Nhập link ISO tuỳ chọn"
read -p "➤ Nhập số (1–7): " choice

case "$choice" in
  1)
    WIN_ISO="https://archive.org/download/vultr-update-0907/Win10_ltsc_x64FRE_en-us.iso"
    ;;
  2)
    WIN_ISO="https://archive.org/download/vultr-update-0907/Windows_Server_2022.iso"
    ;;
  3)
    WIN_ISO="https://archive.org/download/vultr-update-0907/Windows11.iso"
    ;;
  4)
    WIN_ISO="https://archive.org/download/vultr-update-0907/Windows%20%C3%9764.iso"
    ;;
  5)
    WIN_ISO="https://archive.org/download/vultr-update-0907/Windows_Server_2016.ISO"
    ;;
  6)
    WIN_ISO="https://archive.org/download/vultr-update-0907/Windows_Server_2019.iso"
    ;;
  7)
    read -p "🔗 Nhập URL ISO: " WIN_ISO
    ;;
  *)
    echo "❌ Lựa chọn không hợp lệ."; exit 1 ;;
esac

echo "[+] Tải Windows ISO..."
wget -O win.iso "$WIN_ISO"

echo "[+] Tải VirtIO driver..."
wget -O virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso

echo "[+] Tạo file autounattend.xml..."
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
          <CommandLine>cmd /c ping -n 1 google.com > C:\net-check.txt</CommandLine>
          <Order>4</Order>
        </SynchronousCommand>
      </FirstLogonCommands>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
</unattend>
EOF

echo "[+] Đóng ISO autounattend..."
mkdir -p iso && cp autounattend.xml iso/
genisoimage -o autounattend.iso -r -J iso/

echo "[+] Tạo ổ đĩa ảo..."
qemu-img create -f qcow2 "$DISK_NAME" "30G"

echo "[+] Khởi chạy cài đặt Windows..."
nohup qemu-system-x86_64   -enable-kvm   -m "$QEMU_RAM"   -smp "$QEMU_CPUS"   -cpu host   -drive file="$DISK_NAME",format=qcow2   -cdrom win.iso   -drive file=autounattend.iso,media=cdrom   -drive file=virtio-win.iso,media=cdrom   -net nic -net user,hostfwd=tcp::${RDP_PORT}-:3389   -nographic > qemu.log 2>&1 &

echo ""
echo "✅ Windows đang được cài đặt âm thầm (headless)..."
echo "🖥️ RDP: $(curl -s ifconfig.me):${RDP_PORT}"
echo "🔑 Đăng nhập: ${USERNAME} / ${PASSWORD}"
echo "⏳ Đợi khoảng 10–20 phút, sau đó bạn có thể RDP vào dùng!"
echo ""
