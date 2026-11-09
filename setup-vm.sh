#!/usr/bin/env bash
# setup-vm.sh - create (or destroy) a KVM VM for running Claude Code in isolation.
# Usage: ./setup-vm.sh [up|destroy]      Settings: ./config.env      Docs: README.md
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }
[ "$(id -u)" -ne 0 ] || die "run as your normal user, not root (the script calls sudo itself)"
# shellcheck disable=SC1091
[ ! -f config.env ] || . ./config.env

# ---- settings (override them in config.env) --------------------------------
VM_NAME=${VM_NAME:-claude-vm}
VM_USER=${VM_USER:-$(id -un)}
VM_UID=${VM_UID:-$(id -u)}        # must equal your host uid: virtiofs does not remap owners
RAM_MB=${RAM_MB:-8192}
VCPUS=${VCPUS:-4}
DISK_GB=${DISK_GB:-100}
GUEST_IMAGE=${GUEST_IMAGE:-}      # path to a downloaded cloud image (qcow2), required
GUEST_IMAGE_SHA256=${GUEST_IMAGE_SHA256:-}
SHARE_DIR=${SHARE_DIR:-}          # host folder to share with the VM, or "none", required
GUEST_MOUNT=${GUEST_MOUNT:-/home/$VM_USER/Dev}
OSINFO=${OSINFO:-fedora-unknown}  # see: virt-install --osinfo list
NETWORK=${NETWORK:-default}
URI=${URI:-qemu:///system}
IMAGES_DIR=${IMAGES_DIR:-/var/lib/libvirt/images}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/${VM_NAME}_ed25519}
DOCKER_CMD=${DOCKER_CMD:-curl -fsSL https://get.docker.com | sh}
CLAUDE_CMD=${CLAUDE_CMD:-curl -fsSL https://claude.ai/install.sh | bash}   # must not contain single quotes

# LC_ALL=C: we grep virsh output ("Active: yes"), which is translated on non-English hosts.
V() { sudo env LC_ALL=C virsh -c "$URI" "$@"; }
SSH_CFG=$HOME/.ssh/config
drop_ssh_block() {
  [ -f "$SSH_CFG" ] || return 0
  sed -i "/^# >>> $VM_NAME >>>\$/,/^# <<< $VM_NAME <<<\$/d" "$SSH_CFG"
}

up() {
  # 1. checks: fail early, before anything is changed
  [ -f "$GUEST_IMAGE" ] || die "set GUEST_IMAGE in config.env to a downloaded cloud image (qcow2), see README"
  [ -n "$SHARE_DIR" ] || die "set SHARE_DIR in config.env to the host folder to share (or 'none')"
  for c in virsh virt-install qemu-img ssh ssh-keygen; do
    command -v "$c" >/dev/null || die "missing command '$c', see README prerequisites"
  done
  [ -e /dev/kvm ] || die "/dev/kvm not found: enable virtualization in your firmware"
  V dominfo "$VM_NAME" >/dev/null 2>&1 && die "VM '$VM_NAME' already exists (run: $0 destroy)"
  # net-list --name prints only the names of ACTIVE networks: no translated text to parse
  active_nets=$(V net-list --name) || die "cannot query libvirt ($URI): is libvirtd running? (README: prerequisites)"
  grep -Fxq "$NETWORK" <<<"$active_nets" || die "libvirt network '$NETWORK' is not active. Active networks: ${active_nets:-none}. Try: sudo virsh -c $URI net-start $NETWORK"
  [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || log "WARNING: ip_forward is 0, the VM will have no internet (README: troubleshooting)"
  if systemctl is-active --quiet docker 2>/dev/null; then
    log "WARNING: Docker runs on this host and may block VM traffic (README: troubleshooting)"
  fi
  FS=(); MOUNT_CMD=true
  if [ "$SHARE_DIR" != none ]; then
    [ -d "$SHARE_DIR" ] || die "shared folder not found: $SHARE_DIR"
    SHARE_DIR=$(realpath "$SHARE_DIR")
    case $SHARE_DIR in "$HOME"|/) die "refusing to share '$SHARE_DIR': share one project folder";; esac
    ok=0
    for p in "$(command -v virtiofsd || true)" /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd /usr/lib/virtiofsd; do
      [ -n "$p" ] && [ -x "$p" ] && ok=1
    done
    [ "$ok" = 1 ] || die "virtiofsd not found, see README prerequisites (or set SHARE_DIR=none)"
    # shellcheck disable=SC2054  # commas are virt-install option syntax
    FS=(--memorybacking source.type=memfd,access.mode=shared
        --filesystem "source=$SHARE_DIR,target=dev,driver.type=virtiofs")
    MOUNT_CMD="mkdir -p $GUEST_MOUNT; echo 'dev $GUEST_MOUNT virtiofs defaults,nofail 0 0' >> /etc/fstab; systemctl daemon-reload; mount $GUEST_MOUNT"
  fi
  DISK=$IMAGES_DIR/$VM_NAME.qcow2
  sudo test ! -e "$DISK" || die "$DISK already exists"
  if [ -n "$GUEST_IMAGE_SHA256" ]; then
    echo "$GUEST_IMAGE_SHA256  $GUEST_IMAGE" | sha256sum -c - >/dev/null || die "checksum mismatch for $GUEST_IMAGE"
  else
    log "WARNING: GUEST_IMAGE_SHA256 not set, the image is not verified"
  fi

  # 2. SSH key, disk, cloud-init
  [ -f "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "$VM_NAME" -f "$SSH_KEY"
  sudo cp "$GUEST_IMAGE" "$DISK"
  sudo qemu-img resize "$DISK" "${DISK_GB}G"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/user-data" <<EOF
#cloud-config
hostname: $VM_NAME
users:
  - name: $VM_USER
    uid: $VM_UID
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$SSH_KEY.pub")
package_update: true
packages: [git]
runcmd:
  - |
    $MOUNT_CMD
    $DOCKER_CMD
    usermod -aG docker $VM_USER
    systemctl enable --now docker
    runuser -l $VM_USER -c '$CLAUDE_CMD'
EOF

  # 3. create and start the VM
  log "Creating VM '$VM_NAME' (${RAM_MB} MB RAM, $VCPUS vCPUs, ${DISK_GB} GB disk)"
  sudo virt-install --connect "$URI" --name "$VM_NAME" --memory "$RAM_MB" --vcpus "$VCPUS" \
    --import --osinfo "$OSINFO" --disk "path=$DISK,format=qcow2" \
    --cloud-init "user-data=$tmp/user-data" --network "network=$NETWORK" \
    --noautoconsole "${FS[@]}"

  # 4. wait for it, write the SSH alias, check the result
  log "Waiting for an IP address"
  IP=""
  for _ in $(seq 60); do
    IP=$(V domifaddr "$VM_NAME" --source lease 2>/dev/null | awk '/ipv4/ {sub("/.*","",$4); print $4; exit}' || true)
    [ -n "$IP" ] && break
    sleep 3
  done
  [ -n "$IP" ] || die "the VM got no IP address (README: troubleshooting)"
  drop_ssh_block
  mkdir -p "$HOME/.ssh"; touch "$SSH_CFG"; chmod 600 "$SSH_CFG"; cp "$SSH_CFG" "$SSH_CFG.bak"
  cat >> "$SSH_CFG" <<EOF
# >>> $VM_NAME >>>
Host $VM_NAME
  HostName $IP
  User $VM_USER
  IdentityFile $SSH_KEY
  IdentitiesOnly yes
  ForwardAgent no
  StrictHostKeyChecking accept-new
# <<< $VM_NAME <<<
EOF
  ssh-keygen -R "$IP" >/dev/null 2>&1 || true
  log "Waiting for SSH, then for cloud-init (installs Docker and Claude Code, a few minutes)"
  for _ in $(seq 60); do
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$VM_NAME" true 2>/dev/null && break
    sleep 5
  done
  ssh -o BatchMode=yes "$VM_NAME" true || die "cannot SSH to the VM (README: troubleshooting)"
  ssh "$VM_NAME" 'cloud-init status --wait' || true
  log "Checks"
  SMOKE_MOUNT=$([ "$SHARE_DIR" = none ] || echo "$GUEST_MOUNT")
  # shellcheck disable=SC2029  # expanding on the client side is intended
  ssh "$VM_NAME" "MOUNT='$SMOKE_MOUNT' bash -s" <<'EOF' || true
chk() { if eval "$2" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; fi; }
chk "docker installed" 'command -v docker'
chk "claude installed" 'command -v claude || test -x ~/.local/bin/claude'
[ -z "$MOUNT" ] || chk "shared folder writable" 'touch "$MOUNT/.vm-test" && rm "$MOUNT/.vm-test"'
EOF
  log "Done. Connect your editor to the SSH host '$VM_NAME', then run 'claude' in the VM and sign in."
}

destroy() {
  read -r -p "Delete VM '$VM_NAME', its disk and its snapshots? The shared folder is NOT touched. [y/N] " a
  [[ $a =~ ^[Yy] ]] || die "aborted"
  V destroy "$VM_NAME" 2>/dev/null || true
  V undefine "$VM_NAME" --snapshots-metadata --remove-all-storage \
    || V undefine "$VM_NAME" --nvram --snapshots-metadata --remove-all-storage
  drop_ssh_block
  log "Removed. The SSH key $SSH_KEY was kept."
}

case ${1:-up} in
  up) up ;;
  destroy) destroy ;;
  *) die "usage: $0 [up|destroy]" ;;
esac
