#!/bin/bash
set -e

# 1. Thông tin file image và thư mục
IMG_URL="https://www.dropbox.com/scl/fi/wozij42y4dsj4begyjwj1/10-lite.img?rlkey=lyb704acrmr1k023b81w3jpsk&st=e3b81z4i&dl=1"
IMG_DIR="/var/lib/libvirt/images"
IMG_FILE="$IMG_DIR/10-lite.img"
RDP_PORT=2025
VM_RAM=3072
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

# 2. Tự động detect dung lượng ổ cứng thật của VPS (không giới hạn)
if lsblk | grep -q vda; then
  DEV_DISK="/dev/vda"
else
  DEV_DISK="/dev/sda"
fi

DISK_SIZE=$(lsblk -b -d -n -o SIZE $DEV_DISK)
DISK_SIZE_GB=$((DISK_SIZE/1024/1024/1024))

# Resize đúng bằng ổ thật - trừ 2GB cho an toàn
if [ $DISK_SIZE_GB -gt 10 ]; then
  TARGET_SIZE="$((DISK_SIZE_GB - 2))G"
else
  TARGET_SIZE="${DISK_SIZE_GB}G"
fi

echo "🟢 Đang tăng dung lượng file img lên $TARGET_SIZE (ổ thật: ${DISK_SIZE_GB}GB)..."
qemu-img resize "$IMG_FILE" $TARGET_SIZE

NET_MODEL="e1000"

echo "🟢 Khởi động Windows VM trên QEMU/KVM với RDP port $RDP_PORT ..."
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
echo ""
echo "💡 **Chú ý:** Ổ C trong Windows ban đầu sẽ vẫn chỉ ~9GB."
echo "Sau khi đăng nhập Windows, hãy mở **Disk Management (diskmgmt.msc)**, click chuột phải vào ổ C: chọn **Extend Volume** để sử dụng hết $TARGET_SIZE (ổ thật VPS)!"
echo ""
echo "Nếu Win Lite không có chức năng Extend Volume, hãy dùng phần mềm AOMEI Partition Assistant hoặc MiniTool Partition Wizard để mở rộng ổ C."
