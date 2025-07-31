#!/bin/bash
set -e

# 1. Thông tin file VDI và thư mục
VDI_URL="https://www.dropbox.com/scl/fi/3qletjo5ktscvvcrp1v3t/11lite-11tb.vdi?rlkey=o6pclbgz0mxusm56nr1izw5w1&st=kh5ho6u5&dl=1"
IMG_DIR="/var/lib/libvirt/images"
VDI_FILE="$IMG_DIR/11lite-11tb.vdi"
IMG_FILE="$IMG_DIR/11lite-11tb.img"
RDP_PORT=2025
VM_RAM=3072
VM_CPU=2

sudo mkdir -p "$IMG_DIR"
cd "$IMG_DIR"

echo "🟢 Đang kiểm tra & cài đặt các gói cần thiết..."
sudo apt update
sudo apt install -y qemu-utils qemu-kvm wget curl

if [ ! -f "$VDI_FILE" ]; then
  echo "🟢 Đang tải file Windows VDI về VPS..."
  wget -O "$VDI_FILE" "$VDI_URL"
else
  echo "🟢 File VDI đã tồn tại: $VDI_FILE"
fi

echo "🟢 Kiểm tra định dạng file VDI..."
qemu-img info "$VDI_FILE"
VDI_FORMAT=$(qemu-img info --output=json "$VDI_FILE" | grep -Po '"format":.*?[^\\]",' | cut -d'"' -f4)

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

echo "🟢 Đang tăng dung lượng file VDI lên $TARGET_SIZE (ổ thật: ${DISK_SIZE_GB}GB)..."
qemu-img resize "$VDI_FILE" $TARGET_SIZE

# 3. Convert VDI sang IMG (raw, sparse) để chạy QEMU/KVM (nếu muốn dùng trực tiếp VDI thì bỏ qua đoạn này, nhưng QEMU KVM luôn hỗ trợ .img/raw tốt nhất)
echo "🟢 Đang chuyển đổi VDI sang IMG (RAW sparse)..."
qemu-img convert -O raw "$VDI_FILE" "$IMG_FILE"

# Kiểm tra lại file .img
qemu-img info "$IMG_FILE"

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
