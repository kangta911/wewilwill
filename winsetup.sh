#!/bin/bash
set -Eeuo pipefail

# ====== CONFIG ======
IMG_URL="https://www.dropbox.com/scl/fi/wozij42y4dsj4begyjwj1/10-lite.img?rlkey=lyb704acrmr1k023b81w3jpsk&st=e3b81z4i&dl=1"
IMG_DIR="/var/lib/libvirt/images"
IMG_FILE="$IMG_DIR/10-lite.img"
RDP_PORT="${RDP_PORT:-2025}"     # export RDP_PORT=4000 để đổi nhanh
VM_NAME="${VM_NAME:-win10lite}"
VM_RAM="${VM_RAM:-2048}"         # MB | export VM_RAM=4096 nếu muốn
VM_CPU="${VM_CPU:-2}"            # vCPU | export VM_CPU=4 nếu muốn
LOG_FILE="${LOG_FILE:-/var/log/winsetup.log}"

# ====== UI HELPERS ======
ts() { date '+%F %T'; }
log() { echo -e "[$(ts)] $*"; }
hr() { echo "------------------------------------------------------------------"; }

spinner() {
  # Usage: spinner "Message..." <PID>
  local msg="$1"; shift
  local pid="$1"
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  printf "[%s] %s " "$(ts)" "$msg"
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % ${#frames} ))
    printf "\r[%s] %s %s" "$(ts)" "$msg" "${frames:$i:1}"
    sleep 0.1
  done
  printf "\r[%s] %s ✅\n" "$(ts)" "$msg"
}

run_with_spinner() {
  # Usage: run_with_spinner "Message..." command args...
  local msg="$1"; shift
  "$@" &
  local pid=$!
  spinner "$msg" "$pid"
  wait "$pid"
}

# ====== APT HANDLERS ======
apt_wait_unlock() {
  local timeout="${1:-180}"  # 3 phút cho 1 vòng
  local waited=0
  local locks=(
    "/var/lib/apt/lists/lock"
    "/var/lib/dpkg/lock"
    "/var/lib/dpkg/lock-frontend"
    "/var/cache/apt/archives/lock"
  )
  while :; do
    local busy=0
    if pgrep -fa 'apt|dpkg|unattended' >/dev/null 2>&1; then
      busy=1
    else
      busy=0
      for f in "${locks[@]}"; do
        [[ -e "$f" ]] && { busy=1; break; }
      done
    fi
    (( busy == 0 )) && break

    (( waited++ ))
    if (( waited >= timeout )); then
      log "⚠️  Quá thời gian chờ APT (${timeout}s). Dừng apt-daily & unattended-upgrades..."
      systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
      systemctl kill --kill-who=main --signal=TERM apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
      sleep 5
      waited=0
    else
      sleep 1
    fi
  done
}

apt_safe_install() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    run_with_spinner "Chờ APT sẵn sàng" apt_wait_unlock 60
    dpkg --configure -a >/dev/null 2>&1 || true
    run_with_spinner "apt update" bash -c 'apt-get update -y'
    local pkgs=(qemu-system-x86 qemu-utils wget curl)
    apt-cache show ufw >/dev/null 2>&1 && pkgs+=(ufw)
    # Retry 3 lần, có spinner
    local i
    for i in {1..3}; do
      if apt-get install -y "${pkgs[@]}" 2>&1 | stdbuf -oL sed 's/^/[apt] /'; then
        return 0
      fi
      log "⚠️  apt-get install thất bại (lần $i). Chờ & thử lại..."
      run_with_spinner "Chờ APT nhả lock" apt_wait_unlock 60
      sleep 3
    done
    log "❌ Cài gói bằng apt-get thất bại sau 3 lần."
    return 1

  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y qemu-kvm qemu-img wget curl | stdbuf -oL sed 's/^/[dnf] /' || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y qemu-kvm qemu-img wget curl | stdbuf -oL sed 's/^/[yum] /' || true
  else
    log "❌ Không tìm thấy apt/dnf/yum để cài gói."
    return 1
  fi
}

open_ports() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    ufw allow "${port}/udp" >/dev/null 2>&1 || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    iptables -I INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
  fi
  if command -v nft >/dev/null 2>&1; then
    nft add rule inet filter input tcp dport "$port" accept >/dev/null 2>&1 || true
    nft add rule inet filter input udp dport "$port" accept >/dev/null 2>&1 || true
  fi
}

# ====== MAIN ======
main() {
  # Log ra file và ra màn hình
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1

  hr; log "START winsetup (log: $LOG_FILE)"; hr

  if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
  $SUDO mkdir -p "$IMG_DIR"
  cd "$IMG_DIR"

  log "BƯỚC [1/6] Cài gói cần thiết"
  apt_safe_install

  log "BƯỚC [2/6] Kiểm tra tăng tốc KVM"
  $SUDO modprobe kvm 2>/dev/null || true
  $SUDO modprobe kvm-intel 2>/dev/null || $SUDO modprobe kvm-amd 2>/dev/null || true
  if [[ -e /dev/kvm ]]; then
    log "✔ /dev/kvm sẵn sàng (sẽ dùng -enable-kvm)."
  else
    log "ℹ️  Không có /dev/kvm → sẽ dùng TCG (chậm hơn)."
  fi

  log "BƯỚC [3/6] Tải/kiểm tra image"
  if [[ ! -f "$IMG_FILE" ]]; then
    log "→ Tải image: $IMG_URL"
    # Hiện progress dạng chấm lớn, mỗi 1GB một dấu
    wget --progress=dot:giga -O "$IMG_FILE" "$IMG_URL" 2>&1 | stdbuf -oL sed 's/^/[wget] /'
  else
    log "→ Image đã tồn tại: $IMG_FILE (bỏ qua tải)."
  fi

  log "→ qemu-img info"
  qemu-img info "$IMG_FILE" | sed 's/^/[img] /' || true
  IMG_FORMAT="$(qemu-img info --output=json "$IMG_FILE" 2>/dev/null | sed -n 's/.*"format": *"\([^"]\+\)".*/\1/p')"
  [[ -z "${IMG_FORMAT:-}" ]] && IMG_FORMAT="raw"
  log "→ Format phát hiện: $IMG_FORMAT"

  log "BƯỚC [4/6] Resize image theo ổ vật lý (chừa 2GB)"
  if command -v lsblk >/dev/null 2>&1; then
    if lsblk | awk '{print $1}' | grep -q '^vda$'; then DEV_DISK="/dev/vda"; else DEV_DISK="/dev/sda"; fi
    if [[ -b "$DEV_DISK" ]]; then
      DISK_SIZE=$(lsblk -b -d -n -o SIZE "$DEV_DISK")
      DISK_SIZE_GB=$((DISK_SIZE/1024/1024/1024))
      if (( DISK_SIZE_GB > 10 )); then
        TARGET_SIZE="$((DISK_SIZE_GB - 2))G"
      else
        TARGET_SIZE="${DISK_SIZE_GB}G"
      fi
      log "→ Resize lên $TARGET_SIZE (ổ thật: ${DISK_SIZE_GB}GB)"
      qemu-img resize -f "$IMG_FORMAT" "$IMG_FILE" "$TARGET_SIZE" | sed 's/^/[resize] /' || true
    else
      log "⚠️  Không tìm thấy block device phù hợp, bỏ qua resize."
    fi
  else
    log "⚠️  lsblk không có, bỏ qua resize."
  fi

  log "BƯỚC [5/6] Mở firewall cho RDP (TCP+UDP ${RDP_PORT})"
  open_ports "$RDP_PORT"
  log "→ Kiểm tra cổng trống"
  if ss -lnt | awk '{print $4}' | grep -q ":${RDP_PORT}$"; then
    log "⚠️  Cổng ${RDP_PORT} đã có tiến trình lắng nghe. Đổi RDP_PORT rồi chạy lại."
    exit 1
  fi

  log "BƯỚC [6/6] Khởi động VM (headless)"
  if [[ -e /dev/kvm ]]; then
    ACCEL="-enable-kvm -cpu host,hv_time,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff"
  else
    ACCEL="-accel tcg,thread=multi -cpu max"
  fi

  if qemu-system-x86_64 -help 2>/dev/null | grep -q io_uring; then
    AIO_MODE="io_uring"
  else
    AIO_MODE="threads"
  fi

  set -x
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
  { set +x; } 2>/dev/null

  # Xác thực qemu đã chạy
  sleep 1
  if pgrep -fa "qemu-system-x86_64.*-name $VM_NAME" >/dev/null; then
    log "✅ VM đã chạy nền."
  else
    log "❌ Không thấy tiến trình QEMU. Kiểm tra log ở: $LOG_FILE"
    exit 1
  fi

  hr
  log "HOÀN TẤT. Kết nối RDP sau 15–45s khi Windows boot xong:"
  echo "  → mstsc /v:<IP_VPS>:${RDP_PORT}"
  echo "  → Forward: host:${RDP_PORT} (TCP+UDP) → guest:3389"
  echo "  → Log đang ghi: $LOG_FILE (xem live: tail -f $LOG_FILE)"
  hr
}

main "$@"
