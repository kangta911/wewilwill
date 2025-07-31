#!/bin/bash
set -e

IMG_URL="http://drive.muavps.net/file/Win2022UEFI.img"
IMG_DIR="/var/lib/libvirt/images"
IMG_FILE="$IMG_DIR/Win2022UEFI.img"
RDP_PORT=2025
VM_RAM=3072
VM_CPU=2

sudo mkdir -p "$IMG_DIR"
cd "$IMG_DIR"

echo "🟢 Đang kiểm tra & cài đặt các gói cần thiết..."
sudo apt update
sudo apt install -y qemu-utils qemu-kvm wget curl ovmf

if [ ! -f "$IMG_FILE" ]; then
  echo "🟢 Đang tải file Windows img về VPS..."
  wget -O "$IMG_FILE" "$IMG_URL"
else
  echo "🟢 File img đã tồn tại: $IMG_FILE"
fi

echo "🟢 Kiểm tra định dạng file img..."
qemu-img info "$IMG_FILE"
IMG_FORMAT=$(qemu-img info --output=json "$IMG_FILE" | grep -Po '"format":.*?[^\\]",' | cut -d'"' -f4)

NET_MODEL="e1000"

# Boot với UEFI
OVMF_FW="/usr/share/OVMF/OVMF_CODE.fd"
if [ ! -f "$OVMF_FW" ]; then
  OVMF_FW="/usr/share/OVMF/OVMF_CODE.fd"
  if [ ! -f "$OVMF_FW" ]; then
    OVMF_FW="/usr/share/qemu/OVMF_CODE.fd"
  fi
fi

echo "🟢 Khởi động Windows VM UEFI trên QEMU/KVM với RDP port $RDP_PORT ..."
qemu-system-x86_64 \
  -enable-kvm \
  -m $VM_RAM \
  -smp $VM_CPU \
  -cpu host \
  -drive file="$IMG_FILE",format=$IMG_FORMAT \
  -net nic,model=$NET_MODEL -net user,hostfwd=tcp::${RDP_PORT}-:3389 \
  -bios "$OVMF_FW" \
  -nographic

IP=$(curl -s ifconfig.me)
echo ""
echo "✅ VM đã chạy xong!"
echo "Bạn có thể truy cập Remote Desktop tới: ${IP}:${RDP_PORT}"
echo "Tài khoản/mật khẩu: dùng thông tin đã setup sẵn trong file img."
