#!/bin/bash
set -e

# Thông tin file img và thư mục
IMG_URL="https://www.dropbox.com/scl/fi/wozij42y4dsj4begyjwj1/10-lite.img?rlkey=lyb704acrmr1k023b81w3jpsk&st=e3b81z4i&dl=1"
IMG_DIR="/var/lib/libvirt/images"
IMG_FILE="$IMG_DIR/10-lite.img"
RDP_PORT=2025
VM_RAM=3072    # MB
VM_CPU=2

sudo mkdir -p "$IMG_DIR"
cd "$IMG_DIR"

echo "🟢 Đang kiểm tra & cài đặt các gói cần thiết..."
sudo apt update
sudo apt install -y qemu-utils qemu-kvm wget curl

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

echo "🟢 Khởi động Windows VM trên QEMU/KVM với RDP port $RDP_PORT ..."

# LỆNH TỐI GIẢN, ĐẢM BẢO KHÔNG BAO GIỜ LỖI TRÙNG BUS
qemu-system-x86_64 \
  -enable-kvm \
  -m $VM_RAM \
  -smp $VM_CPU \
  -cpu host \
  -hda "$IMG_FILE" \
  -net nic,model=$NET_MODEL -net user,hostfwd=tcp::${RDP_PORT}-:3389 \
  -nographic

IP=$(curl -s ifconfig.me)
echo ""
echo "✅ VM đã chạy xong!"
echo "Bạn có thể truy cập Remote Desktop tới: ${IP}:${RDP_PORT}"
echo "Tài khoản/mật khẩu: dùng thông tin đã setup sẵn trong file img."
echo ""
echo "Nếu bạn muốn chuyển sang VirtIO để tối ưu tốc độ, hãy cài driver VirtIO trong Windows rồi chỉnh lại tham số card mạng thành virtio."
