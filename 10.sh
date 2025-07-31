#!/bin/bash
set -e

# === 1. Thông tin file img và thư mục ===
IMG_URL="https://www.dropbox.com/scl/fi/wozij42y4dsj4begyjwj1/10-lite.img?rlkey=lyb704acrmr1k023b81w3jpsk&st=e3b81z4i&dl=1"
IMG_DIR="/var/lib/libvirt/images"
IMG_FILE="$IMG_DIR/10-lite.img"
RDP_PORT=2025
VM_RAM=3072    # MB
VM_CPU=2

# === 2. Tạo thư mục chứa ảnh nếu chưa có ===
sudo mkdir -p "$IMG_DIR"
cd "$IMG_DIR"

# === 3. Đảm bảo đã cài qemu-utils, qemu-kvm, wget, curl ===
echo "🟢 Đang kiểm tra & cài đặt các gói cần thiết..."
sudo apt update
sudo apt install -y qemu-utils qemu-kvm wget curl

# === 4. Tải file img nếu chưa có ===
if [ ! -f "$IMG_FILE" ]; then
  echo "🟢 Đang tải file Windows img về VPS..."
  wget -O "$IMG_FILE" "$IMG_URL"
else
  echo "🟢 File img đã tồn tại: $IMG_FILE"
fi

# === 5. Kiểm tra định dạng file img ===
echo "🟢 Kiểm tra định dạng file img..."
qemu-img info "$IMG_FILE"
IMG_FORMAT=$(qemu-img info --output=json "$IMG_FILE" | grep -Po '"format":.*?[^\\]",' | cut -d'"' -f4)

# === 6. Chọn card mạng phù hợp (e1000) ===
NET_MODEL="e1000"

# === 7. Khởi động máy ảo với QEMU, loại bỏ thiết bị mặc định tránh trùng bus ===
echo "🟢 Khởi động Windows VM trên QEMU/KVM với RDP port $RDP_PORT ..."
qemu-system-x86_64 \
  -enable-kvm \
  -nodefaults \
  -m $VM_RAM \
  -smp $VM_CPU \
  -cpu host \
  -drive file="$IMG_FILE",format=$IMG_FORMAT,if=none,id=disk0 \
  -device ide-hd,drive=disk0,bus=ide.0 \
  -net nic,model=$NET_MODEL -net user,hostfwd=tcp::${RDP_PORT}-:3389 \
  -nographic

# === 8. Hướng dẫn truy cập ===
IP=$(curl -s ifconfig.me)
echo ""
echo "✅ VM đã chạy xong!"
echo "Bạn có thể truy cập Remote Desktop tới: ${IP}:${RDP_PORT}"
echo "Tài khoản/mật khẩu: dùng thông tin đã setup sẵn trong file img."
echo ""
echo "Nếu bạn cần đổi model card mạng về 'virtio' để tăng tốc độ (khi đã cài VirtIO driver trong Windows), hãy sửa biến NET_MODEL và dòng khởi tạo ổ đĩa."
