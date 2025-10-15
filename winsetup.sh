#!/bin/bash
set -Eeuo pipefail
# Hiển thị từng lệnh trước khi chạy
set -x

# ====== CONFIG ======
IMG_URL="https://www.dropbox.com/scl/fi/wozij42y4dsj4begyjwj1/10-lite.img?rlkey=lyb704acrmr1k023b81w3jpsk&st=e3b81z4i&dl=1"
IMG_DIR="/var/lib/libvirt/images"
IMG_FILE="$IMG_DIR/10-lite.img"
RDP_PORT="${RDP_PORT:-2025}"      # đổi nhanh: RDP_PORT=4000 ./winsetup.sh
VM_NAME="${VM_NAME:-win10lite}"
VM_RAM="${VM_RAM:-2048}"          # MB
VM_CPU="${VM_CPU:-2}"             # vCPU
LOG_FILE="${LOG_FILE:-/var/log/winsetup.log}"

# ====== HELPERS ======
ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*"; }
hr(){ echo "------------------------------------------------------------------"; }

apt_wait_unlock(){
  local timeout="${1:-180}" waited=0
  local locks=(/var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock)
  while :; do
    local busy=0
    # In ra các tiến trình apt/dpkg đang chạy (nếu có)
    if pgrep -fa 'apt|dpkg|unattended'; then busy=1; fi
    # In ra file lock còn tồn tại (nếu có)
    for f in "${locks[@]}"; do [[ -e "$f" ]] && { echo "[LOCK] $f tồn tại"; busy=1; }; done
    (( !busy )) && break
    (( waited++ ))
    echo "[WAIT] APT bận... ${waited}s/${timeout}s"
    if (( waited>=timeout )); then
      echo "[ACTION] Dừng apt-daily & apt-daily-upgrade & unattended-upgrades"
      systemctl stop apt-daily.service apt-daily-upgrade.service || true
      systemctl kill --kill-who=main --signal=TERM apt-daily.service apt-daily-upgrade.service || true
      systemctl stop unattended-upgrades.service || true
      sleep 5; waited=0
    else
      sleep 1
    fi
  done
}

apt_safe_install(){
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    export APT_LISTCHANGES_FRONTEND=none
    apt_wait_unlock 60
    dpkg --configure -a || true
    # apt-get update hiển thị đầy đủ
    apt-get -o Dpkg::Use-Pty=0 update -y || true
    local pkgs=(qemu-system-x86 qemu-utils wget curl)
    apt-cache show ufw >/dev/null 2>&1 && pkgs+=(ufw)
    for i in 1 2 3; do
      echo "[APT] Cài gói (lần $i): ${pkgs[*]}"
      if apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Progress-Fancy=1 install -y "${pkgs[@]}"; then
        return 0
      fi
      echo "[APT] Lỗi cài gói — chờ nhả lock rồi thử lại"
      apt_wait_unlock 60; sleep 3
    done
    echo "[APT] THẤT BẠI SAU 3 LẦN"; return 1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y qemu-kvm qemu-img wget curl || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y qemu-kvm qemu-img wget curl || true
  else
    echo "[ERR] Không có apt/dnf/yum"; return 1
  fi
}

open_ports(){
  local port="$1"
  # Không ẩn output — xem rõ rule được thêm
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" || true
    ufw allow "${port}/udp" || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
    iptables -I INPUT -p udp --dport "$port" -j ACCEPT || true
    iptables -S | grep "$port" || true
  fi
  if command -v nft >/dev/null 2>&1; then
    # Thêm rule nếu có table filter
    if nft list table inet filter 2>/dev/null; then
      nft add rule inet filter input tcp dport "$port" accept || true
      nft add rule inet filter input udp dport "$port" accept || true
      nft list ruleset | grep -A2 "dport $port" || true
    fi
  fi
}

main(){
  # log ra file & màn hình (tee), vẫn show full trên stdout
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1

  hr; log "START winsetup (log: $LOG_FILE)"; hr

  [[ "$(id -u)" -eq 0 ]] && SUDO="" || SUDO="sudo"
  $SUDO mkdir -p "$IMG_DIR"
  cd "$IMG_DIR"

  log "B1/6 Cài gói cần thiết"
  apt_safe_install

  log "B2/6 Kiểm tra tăng tốc KVM"
  $SUDO modprobe kvm || true
  $SUDO modprobe kvm-intel || $SUDO modprobe kvm-amd || true
  ls -l /dev/kvm || true
  lscpu | grep -iE 'virt|hyper' || true

  log "B3/6 Tải/kiểm tra image"
  if [[ ! -f "$IMG_FILE" ]]; then
    echo "[DL] $IMG_URL"
    # ép kiểu progress bar cuộn (dễ nhìn)
    wget --progress=bar:force:noscroll -O "$IMG_FILE" "$IMG_URL"
  else
    echo "[DL] Đã có sẵn: $IMG_FILE"
  fi
  echo "[IMG] Thông tin image:"
  qemu-img info "$IMG_FILE" || true
  IMG_FORMAT="$(qemu-img info --output=json "$IMG_FILE" 2>/dev/null | sed -n 's/.*"format": *"\([^"]\+\)".*/\1/p')"
  [[ -z "${IMG_FORMAT:-}" ]] && IMG_FORMAT="raw"
  echo "[IMG] Format: $IMG_FORMAT"

  log "B4/6 Resize image theo ổ vật lý (chừa 2GB)"
  if command -v lsblk >/dev/null 2>&1; then
    lsblk
    if lsblk | awk '{print $1}' | grep -q '^vda$'; then DEV_DISK="/dev/vda"; else DEV_DISK="/dev/sda"; fi
    echo "[DISK] Chọn thiết bị: $DEV_DISK"
    if [[ -b "$DEV_DISK" ]]; then
      DISK_SIZE=$(lsblk -b -d -n -o SIZE "$DEV_DISK")
      DISK_SIZE_GB=$((DISK_SIZE/1024/1024/1024))
      if (( DISK_SIZE_GB > 10 )); then TARGET_SIZE="$((DISK_SIZE_GB - 2))G"; else TARGET_SIZE="${DISK_SIZE_GB}G"; fi
      echo "[RESIZE] -> $TARGET_SIZE (ổ thật: ${DISK_SIZE_GB}GB)"
      qemu-img resize -f "$IMG_FORMAT" "$IMG_FILE" "$TARGET_SIZE" || true
    else
      echo "[RESIZE] Bỏ qua: $DEV_DISK không tồn tại"
    fi
  else
    echo "[RESIZE] Bỏ qua: không có lsblk"
  fi

  log "B5/6 Mở firewall cho RDP (TCP+UDP :${RDP_PORT})"
  open_ports "$RDP_PORT"
  echo "[CHECK] ss -lntu | grep :${RDP_PORT}"
  ss -lntu | grep ":${RDP_PORT}" || true
  if ss -lnt | awk '{print $4}' | grep -q ":${RDP_PORT}$"; then
    echo "[WARN] Port ${RDP_PORT} đã có tiến trình lắng nghe. Đổi RDP_PORT rồi chạy lại."
    exit 1
  fi

  log "B6/6 Khởi động VM (headless)"
  if [[ -e /dev/kvm ]]; then
    ACCEL="-enable-kvm -cpu host,hv_time,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff"
  else
    ACCEL="-accel tcg,thread=multi -cpu max"
  fi
  if qemu-system-x86_64 -help 2>/dev/null | grep -q io_uring; then AIO_MODE="io_uring"; else AIO_MODE="threads"; fi

  # In nguyên lệnh QEMU trước khi chạy
  echo "[QEMU CMD]"
  echo qemu-system-x86_64 \
    $ACCEL -smp "$VM_CPU" -m "$VM_RAM" \
    -name "$VM_NAME" \
    -rtc base=localtime \
    -drive file="$IMG_FILE",format="$IMG_FORMAT",if=ide,cache=writeback,aio="${AIO_MODE}" \
    -netdev user,id=n1,hostfwd=tcp::${RDP_PORT}-:3389,hostfwd=udp::${RDP_PORT}-:3389 \
    -device e1000,netdev=n1 \
    -usb -device usb-tablet \
    -display none \
    -daemonize

  # Chạy QEMU (giữ -x để thấy lỗi nếu có)
  qemu-system-x86_64 \
    $ACCEL -smp "$VM_CPU" -m "$VM_RAM" \
    -name "$VM_NAME" \
    -rtc base=localtime \
    -drive file="$IMG_FILE",format="$IMG_FORMAT",if=ide,cache=writeback,aio="${AIO_MODE}" \
    -netdev user,id=n1,hostfwd=tcp::${RDP_PORT}-:3389,hostfwd=udp::${RDP_PORT}-:3389 \
    -device e1000,netdev=n1 \
    -usb -device usb-tablet \
    -display none \
    -daemonize

  sleep 1
  echo "[PS] QEMU tiến trình:"
  pgrep -fa "qemu-system-x86_64.*-name $VM_NAME" || { echo "[ERR] Không thấy QEMU"; exit 1; }

  hr
  log "HOÀN TẤT — Kết nối RDP khi Windows boot xong:"
  echo "  mstsc /v:<IP_VPS>:${RDP_PORT}"
  echo "  Forward: host:${RDP_PORT} (TCP+UDP) → guest:3389"
  echo "  Log: $LOG_FILE  (theo dõi live: tail -f $LOG_FILE)"
  hr
}

main "$@"
