#!/bin/bash
#
# Artix Linux (dinit) LUKS Encrypted Installation Script (July 2026)
# Target: Framework 12 Laptop (Intel iGPU). Adjust GPU packages if yours differs.
#
# Disk layout ("encryption: root only"):
#   p1: EFI System Partition (FAT32), mounted /boot  -- UNENCRYPTED
#       Holds GRUB + kernel + initramfs. GRUB never touches LUKS.
#   p2: LUKS2 (argon2id) -> btrfs (@,@home,@var,@tmp) -- ENCRYPTED root
#       Unlocked at boot by mkinitcpio's encrypt hook via cryptdevice= param.
#   -> ONE passphrase prompt at boot (from the initramfs).
#
# Features:
#   * dinit init system with all services enabled via boot.d symlinks
#     (dinitctl --offline is broken on current ISOs; symlinks are the fix)
#   * Plasma 6 + SDDM with elogind/dbus (dinit variants)
#   * KDE core apps + common extras (Dolphin, Konsole, Kate, Ark, Okular, etc.)
#   * SMB/CIFS network shares in Dolphin (kio-extras + samba)
#   * zram compressed swap (no btrfs swap-file issues)
#   * NetworkManager for WiFi/Ethernet
#   * PipeWire audio via dinit user services
#   * Intel microcode, linux-firmware
#
# Resume support:
#   Uses marker files in /tmp/.artix_state. If the script dies partway,
#   DO NOT re-run the outer script (it re-partitions). Instead:
#       artix-chroot /mnt /bin/bash /root/chroot-install.sh
#
# Run from the official Artix Live USB (any DE/init), as root.

set -euo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND"; exit 1' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${BLUE}[$(date +%T)]${NC} $1"; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

exec > >(tee -a /root/artix-install.log) 2>&1
echo "=== Artix dinit LUKS install started at $(date) ==="

# ================================================================ pre-flight
[[ $EUID -eq 0 ]] || error "Run as root."
[[ -d /sys/firmware/efi ]] || error "Not booted in UEFI mode. Reboot the Live USB in UEFI mode."

log "Checking required tools..."
for cmd in sgdisk parted cryptsetup mkfs.vfat mkfs.btrfs basestrap fstabgen artix-chroot blkid; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        warn "$cmd missing; attempting to install on the live medium..."
        case "$cmd" in
            sgdisk)       pacman -Sy --noconfirm gptfdisk ;;
            parted)       pacman -Sy --noconfirm parted ;;
            cryptsetup)   pacman -Sy --noconfirm cryptsetup ;;
            mkfs.vfat)    pacman -Sy --noconfirm dosfstools ;;
            mkfs.btrfs)   pacman -Sy --noconfirm btrfs-progs ;;
            basestrap|fstabgen|artix-chroot) pacman -Sy --noconfirm artools ;;
            *)            error "Missing critical tool: $cmd" ;;
        esac
    fi
done
success "Tools ready."

# ============================================== gather all user input up front
log "Available disks:"
lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -Ev 'loop|sr0' | cat

warn "!!! ALL DATA ON THE SELECTED DISK WILL BE DESTROYED !!!"
read -rp "Target disk WITHOUT /dev/ (e.g. nvme0n1): " DISK_NAME
DISK="/dev/${DISK_NAME}"
[[ -b "$DISK" ]] || error "Invalid disk: $DISK"

# Partition suffix: nvme/mmc/loop use 'p' (nvme0n1p1), sd* do not (sda1).
if [[ "$DISK_NAME" =~ (nvme|mmcblk|loop) ]]; then P="p"; else P=""; fi
EFI_PART="${DISK}${P}1"
ROOT_PART="${DISK}${P}2"

read -rp "Hostname [artix]: " HOSTNAME_IN;  HOSTNAME_IN="${HOSTNAME_IN:-artix}"
read -rp "Timezone  [UTC] (e.g. Europe/Berlin, America/New_York): " TZ_IN; TZ_IN="${TZ_IN:-UTC}"
read -rp "Your username: " USERNAME
[[ -n "$USERNAME" ]] || error "Username cannot be empty."

echo
warn "About to ERASE $DISK:"
echo "   ${EFI_PART}  -> EFI System Partition (1 GiB, FAT32, /boot, unencrypted)"
echo "   ${ROOT_PART}  -> LUKS2 encrypted root (btrfs)"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || error "Aborted."

# ================================================== partition + LUKS + btrfs
MOUNT_OPTS="noatime,compress=zstd:3,space_cache=v2,discard=async"

log "Wiping and partitioning $DISK..."
wipefs -a "$DISK" || true
sgdisk --zap-all "$DISK" || true
parted -s "$DISK" mklabel gpt
parted -s -a optimal "$DISK" mkpart ESP fat32 1MiB 1GiB
parted -s "$DISK" set 1 esp on
parted -s -a optimal "$DISK" mkpart root 1GiB 100%
partprobe "$DISK" || true; sleep 2

log "Formatting EFI System Partition..."
mkfs.vfat -F32 -n EFI "$EFI_PART"

log "Creating LUKS2 (argon2id) on $ROOT_PART -- set your passphrase now (twice)..."
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id "$ROOT_PART"
log "Unlock it once to continue:"
cryptsetup open "$ROOT_PART" cryptroot

log "Creating btrfs + subvolumes..."
mkfs.btrfs -f -L ROOT /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
for sv in @ @home @var @tmp; do btrfs subvolume create "/mnt/$sv"; done
umount /mnt

mount -o "subvol=@,$MOUNT_OPTS" /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var,tmp,boot}
mount -o "subvol=@home,$MOUNT_OPTS" /dev/mapper/cryptroot /mnt/home
mount -o "subvol=@var,$MOUNT_OPTS"  /dev/mapper/cryptroot /mnt/var
mount -o "subvol=@tmp,$MOUNT_OPTS"  /dev/mapper/cryptroot /mnt/tmp
mount "$EFI_PART" /mnt/boot
success "Partitions, LUKS, and btrfs ready."

# ========================================================== capture UUIDs
LUKS_UUID=$(cryptsetup luksUUID "$ROOT_PART")
BTRFS_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
success "LUKS=$LUKS_UUID  btrfs=$BTRFS_UUID  ESP=$EFI_UUID"

# ============================================= basestrap (Artix's pacstrap)
log "Installing base system with dinit..."
basestrap /mnt \
    base base-devel dinit elogind-dinit \
    linux linux-headers linux-firmware intel-ucode \
    cryptsetup btrfs-progs \
    grub efibootmgr dosfstools \
    networkmanager networkmanager-dinit \
    openssh openssh-dinit \
    sudo vi nano less wget

log "Generating fstab..."
fstabgen -U /mnt >> /mnt/etc/fstab
# Remove subvolid= from btrfs entries (changes on snapshot/rollback, breaks boot).
sed -i 's/subvolid=[0-9]*,//g' /mnt/etc/fstab
success "Base system installed; fstab generated."

# =============================== pass parameters into chroot via temp files
mkdir -p /mnt/tmp
printf '%s\n' "$LUKS_UUID"   > /mnt/tmp/luks_uuid.txt
printf '%s\n' "$BTRFS_UUID"  > /mnt/tmp/btrfs_uuid.txt
printf '%s\n' "$EFI_UUID"    > /mnt/tmp/efi_uuid.txt
printf '%s\n' "$HOSTNAME_IN" > /mnt/tmp/hostname.txt
printf '%s\n' "$TZ_IN"       > /mnt/tmp/timezone.txt
printf '%s\n' "$USERNAME"    > /mnt/tmp/username.txt

# =====================================================================
#  CHROOT SCRIPT  (everything below runs INSIDE the new system)
# =====================================================================
log "Writing chroot script..."
cat > /mnt/root/chroot-install.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
trap 'echo "CHROOT ERROR at line $LINENO: $BASH_COMMAND"; exit 1' ERR

exec > >(tee -a /root/artix-install.log) 2>&1
echo "=== Chroot install started at $(date) ==="

log()    { echo -e "\033[0;34m[CHROOT $(date +%T)]\033[0m $1"; }
success(){ echo -e "\033[0;32m[CHROOT OK]\033[0m $1"; }
warn()   { echo -e "\033[1;33m[CHROOT WARN]\033[0m $1"; }

STATE=/tmp/.artix_state; mkdir -p "$STATE"
done_step(){ [[ -f "$STATE/$1" ]]; }
mark(){ touch "$STATE/$1"; }

# ---- read parameters passed in from the outer script -------------------
LUKS_UUID=$(cat /tmp/luks_uuid.txt)
BTRFS_UUID=$(cat /tmp/btrfs_uuid.txt)
EFI_UUID=$(cat /tmp/efi_uuid.txt)
HOSTNAME_IN=$(cat /tmp/hostname.txt)
TZ_IN=$(cat /tmp/timezone.txt)
USERNAME=$(cat /tmp/username.txt)

# Helper: enable a dinit service for boot (symlink method; works in chroot
# where dinitctl --offline is known-broken on current ISOs).
dinit_enable() {
    local svc="$1"
    mkdir -p /etc/dinit.d/boot.d
    if [[ -f "/etc/dinit.d/$svc" ]]; then
        ln -sf "/etc/dinit.d/$svc" "/etc/dinit.d/boot.d/$svc"
        success "Enabled dinit service: $svc"
    else
        warn "Dinit service file not found: $svc (skipped)"
    fi
}

# ---- 1. timezone / locale / hostname -----------------------------------
if ! done_step localetime; then
    log "Timezone=$TZ_IN, locale=en_US.UTF-8, hostname=$HOSTNAME_IN..."
    ln -sf "/usr/share/zoneinfo/$TZ_IN" /etc/localtime
    hwclock --systohc
    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    sed -i 's/^#C.UTF-8 UTF-8/C.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    echo "$HOSTNAME_IN" > /etc/hostname
    cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME_IN}.localdomain ${HOSTNAME_IN}
EOF
    mark localetime
fi

# ---- 2. mkinitcpio (encrypt hook for LUKS, btrfs support) ---------------
if ! done_step initcpio; then
    log "Configuring mkinitcpio for LUKS + btrfs..."
    # The 'encrypt' hook unlocks LUKS at boot; btrfs-progs is already installed
    # for btrfs filesystem support. 'keyboard' must come before 'encrypt'.
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    mkinitcpio -P
    success "initramfs rebuilt with encrypt hook."
    mark initcpio
fi

# ---- 3. GRUB (EFI, reads from the UNENCRYPTED /boot) --------------------
if ! done_step grub; then
    log "Installing GRUB (EFI)..."
    # cryptdevice tells the encrypt hook which partition to unlock and what
    # to name the mapper device. root= then points to the unlocked device.
    cat > /etc/default/grub <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Artix"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"
GRUB_CMDLINE_LINUX="cryptdevice=UUID=${LUKS_UUID}:cryptroot:allow-discards root=/dev/mapper/cryptroot rootflags=subvol=@"
GRUB_DISABLE_OS_PROBER=true
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
EOF
    grub-install --target=x86_64-efi --efi-directory=/boot \
        --bootloader-id=Artix --removable --recheck
    grub-mkconfig -o /boot/grub/grub.cfg
    success "GRUB installed (LUKS unlocked by the initramfs encrypt hook)."
    mark grub
fi

# ---- 4. Plasma desktop + SDDM + KDE apps + SMB --------------------------
if ! done_step desktop; then
    log "Installing Plasma 6, SDDM, KDE apps, SMB, and desktop plumbing..."
    pacman -S --noconfirm --needed \
        plasma-meta sddm sddm-dinit \
        xorg-server xorg-xinit \
        elogind-dinit dbus-dinit \
        haveged \
        pipewire pipewire-pulse pipewire-jack wireplumber \
        pipewire-dinit wireplumber-dinit \
        dolphin konsole kate ark okular gwenview spectacle \
        kcalc filelight kwrite kfind kdialog khelpcenter \
        kio-extras samba smbclient \
        kdegraphics-thumbnailers ffmpegthumbs \
        power-profiles-daemon \
        noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-liberation \
        bash-completion man-db man-pages

    # Machine-id is required for SDDM/elogind sessions.
    [[ -s /etc/machine-id ]] || dbus-uuidgen > /etc/machine-id
    # SDDM greeter needs sddm user in video group.
    usermod -a -G video sddm 2>/dev/null || true

    success "Desktop environment installed."
    mark desktop
fi

# ---- 5. zram swap (compressed swap in RAM) --------------------------------
if ! done_step zram; then
    log "Setting up zram compressed swap..."
    # dinit scripted service for zram
    cat > /etc/dinit.d/zram <<'EOF'
type = scripted
command = /usr/local/bin/zram-start
stop-command = /usr/local/bin/zram-stop
logfile = /var/log/zram.log
depends-on = boot
EOF
    cat > /usr/local/bin/zram-start <<'EOF'
#!/bin/bash
modprobe zram
zramctl /dev/zram0 --size 8G --algorithm zstd
mkswap /dev/zram0
swapon /dev/zram0 -p 10
EOF
    cat > /usr/local/bin/zram-stop <<'EOF'
#!/bin/bash
swapoff /dev/zram0 2>/dev/null
zramctl --reset /dev/zram0 2>/dev/null
modprobe -r zram 2>/dev/null
true
EOF
    chmod +x /usr/local/bin/zram-start /usr/local/bin/zram-stop
    success "zram swap configured (8G zstd, dinit scripted service)."
    mark zram
fi

# ---- 6. enable dinit services -------------------------------------------
# dinitctl --offline is broken on current ISOs (20260402+), so we use
# symlinks directly. This is the canonical fallback per the Artix wiki.
if ! done_step services; then
    log "Enabling dinit services via boot.d symlinks..."
    mkdir -p /etc/dinit.d/boot.d

    dinit_enable NetworkManager
    dinit_enable sddm
    dinit_enable elogind
    dinit_enable dbus
    dinit_enable zram
    dinit_enable sshd

    success "Services enabled for boot."
    mark services
fi

# ---- 7. sudo + user + passwords ----------------------------------------
if ! done_step user; then
    log "Configuring sudo and creating user '$USERNAME'..."
    # Ensure sudo is installed (should be from basestrap, but guard it).
    command -v sudo >/dev/null || pacman -S --noconfirm sudo
    mkdir -p /etc/sudoers.d
    chmod 0750 /etc/sudoers.d
    grep -qE '^[@#]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers 2>/dev/null \
        || echo '@includedir /etc/sudoers.d' >> /etc/sudoers

    if ! id "$USERNAME" &>/dev/null; then
        useradd -m -G wheel,audio,video,input,storage,optical,power,users -s /bin/bash "$USERNAME"
    fi

    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
    chmod 0440 /etc/sudoers.d/wheel
    command -v visudo >/dev/null && visudo -c >/dev/null

    echo; echo ">>> Set password for USER '$USERNAME':"; passwd "$USERNAME"
    echo; echo ">>> Set password for ROOT:";            passwd root
    mark user
fi

# ---- 8. Arch Linux repos (for extra packages from Arch) ------------------
# Artix can use Arch repos for packages not in the Artix repos.
# This is optional but recommended for a complete desktop.
if ! done_step archrepos; then
    log "Enabling Arch Linux repositories (lib32, extra)..."
    pacman -S --noconfirm --needed artix-archlinux-support
    # Append Arch repos if not already present.
    if ! grep -q '^\[extra\]' /etc/pacman.conf; then
        cat >> /etc/pacman.conf <<'EOF'

# Arch Linux repositories (via artix-archlinux-support)
[extra]
Include = /etc/pacman.d/mirrorlist-arch

[multilib]
Include = /etc/pacman.d/mirrorlist-arch
EOF
    fi
    pacman -Sy
    success "Arch repos enabled."
    mark archrepos
fi

echo "=== Chroot install finished at $(date) ==="
success "Done inside chroot."
CHROOT_EOF

chmod +x /mnt/root/chroot-install.sh

# ================================================================ run chroot
# NOTE: the chroot script is resumable via markers in /tmp/.artix_state.
# If it stops partway, DO NOT re-run this whole outer script (it re-partitions
# and wipes the disk). Instead re-run only the chroot part:
#     artix-chroot /mnt /bin/bash /root/chroot-install.sh
log "Entering chroot..."
artix-chroot /mnt /bin/bash /root/chroot-install.sh

success "Installation completed!"
echo
warn "Finish with:"
echo "   umount -R /mnt"
echo "   cryptsetup close cryptroot"
echo "   reboot"
echo
echo "On boot: one LUKS passphrase prompt (from the initramfs), then SDDM."
echo "Log in as '$USERNAME'. At the session picker, 'Plasma (X11)' is the most"
echo "reliable first login; Wayland can be tried afterwards."
echo
echo "SMB shares: type smb://server-ip/sharename in Dolphin's address bar."
echo "Bookmark via right-click -> 'Add to Places' for quick access."
echo
echo "Post-install tip: to manage services, use:"
echo "   sudo dinitctl enable <service>    # enable + start"
echo "   sudo dinitctl list                # show running services"
echo "   sudo dinitctl status <service>    # check a service"
