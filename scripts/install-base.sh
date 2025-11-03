#!/usr/bin/env bash

set -euo pipefail

if [[ $PACKER_BUILDER_TYPE == "qemu" ]]; then
  DISK='/dev/vda'
else
  DISK='/dev/sda'
fi

FQDN='pwnbox.local'
KEYMAP='us'
LANGUAGE='en_US.UTF-8'
PASSWORD="$(/usr/bin/openssl passwd -6 'vagrant')"
TIMEZONE='UTC'

CONFIG_SCRIPT='/usr/local/bin/arch-config.sh'
EFI_PARTITION="${DISK}1"
ROOT_PARTITION="${DISK}2"
TARGET_DIR='/mnt'

COUNTRY="${COUNTRY:-SG}"
MIRRORLIST="https://archlinux.org/mirrorlist/?country=${COUNTRY}&protocol=http&protocol=https&ip_version=4&use_mirror_status=on"

echo ">>>> Clearing partition table on ${DISK}"
/usr/bin/sgdisk --zap-all "${DISK}"
/usr/bin/dd if=/dev/zero "of=${DISK}" bs=512 count=2048
/usr/bin/wipefs --all "${DISK}"
/usr/bin/sgdisk --new=1:1MiB:+512MiB --typecode=1:ef00 --change-name=1:EFI "${DISK}"
/usr/bin/sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:root "${DISK}"

echo ">>>> Partition table"
/usr/bin/sgdisk --print "${DISK}"

echo ">>>> Creating EFI filesystem (FAT32)"
/usr/bin/mkfs.fat -F32 -n EFI "${EFI_PARTITION}"

echo ">>>> Creating root filesystem (ext4)"
/usr/bin/mkfs.ext4 -m 0 -F -L root "${ROOT_PARTITION}"

echo ">>>> Mounting root partition to ${TARGET_DIR}"
/usr/bin/mount -o noatime,errors=remount-ro "${ROOT_PARTITION}" "${TARGET_DIR}"

echo ">>>> Mounting EFI partition to ${TARGET_DIR}/boot"
/usr/bin/mount --mkdir "${EFI_PARTITION}" "${TARGET_DIR}/boot"

echo ">>>> Configuring pacman mirrors for ${COUNTRY}"
curl -s "${MIRRORLIST}" | sed 's/^#Server/Server/' > /etc/pacman.d/mirrorlist

echo ">>>> Installing base system"
/usr/bin/pacstrap "${TARGET_DIR}" base base-devel linux linux-firmware 

echo ">>>> Installing essential packages"
/usr/bin/arch-chroot "${TARGET_DIR}" pacman -S --noconfirm \
  efibootmgr \
  networkmanager \
  openssh \
  sudo

echo ">>>> Generating filesystem table"
/usr/bin/genfstab -U "${TARGET_DIR}" >> "${TARGET_DIR}/etc/fstab"

echo ">>>> Creating system configuration script"
/usr/bin/install --mode=0755 /dev/null "${TARGET_DIR}${CONFIG_SCRIPT}"

CONFIG_SCRIPT_SHORT="$(basename "${CONFIG_SCRIPT}")"
cat <<-EOF > "${TARGET_DIR}${CONFIG_SCRIPT}"
#!/usr/bin/env bash
set -eu

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Configuring hostname, timezone, and keymap"
echo '${FQDN}' > /etc/hostname
/usr/bin/ln -sf '/usr/share/zoneinfo/${TIMEZONE}' /etc/localtime
/usr/bin/hwclock --systohc
echo 'KEYMAP=${KEYMAP}' > /etc/vconsole.conf

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Configuring hosts file"
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${FQDN} pwnbox
HOSTS

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Configuring locale"
/usr/bin/sed -i 's/#${LANGUAGE}/${LANGUAGE}/' /etc/locale.gen
/usr/bin/locale-gen
echo 'LANG=${LANGUAGE}' > /etc/locale.conf

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Creating initramfs"
/usr/bin/mkinitcpio -p linux

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Installing systemd-boot bootloader"
/usr/bin/bootctl install

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Configuring bootloader entries"
cat > /boot/loader/loader.conf <<LOADER
default arch.conf
timeout 3
console-mode max
editor no
LOADER

cat > /boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=LABEL=root rw
ENTRY

cat > /boot/loader/entries/arch-fallback.conf <<FALLBACK
title   Arch Linux (fallback)
linux   /vmlinuz-linux
initrd  /initramfs-linux-fallback.img
options root=LABEL=root rw
FALLBACK

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Setting root password"
/usr/bin/usermod --password '${PASSWORD}' root

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Configuring network"
# Disable systemd Predictable Network Interface Names for Vagrant compatibility
/usr/bin/ln -sf /dev/null /etc/udev/rules.d/80-net-setup-link.rules
/usr/bin/systemctl enable NetworkManager.service
/usr/bin/systemctl enable systemd-resolved.service

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Configuring SSH daemon"
/usr/bin/sed -i 's/#UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
/usr/bin/sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
/usr/bin/sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
/usr/bin/sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
/usr/bin/systemctl enable sshd.service

# Workaround for SSH connection issue after reboot
echo ">>>> ${CONFIG_SCRIPT_SHORT}: Installing rng-tools for entropy generation"
/usr/bin/pacman -S --noconfirm rng-tools
/usr/bin/systemctl enable rngd.service

# Vagrant user setup
echo ">>>> ${CONFIG_SCRIPT_SHORT}: Creating vagrant user"
/usr/bin/useradd --password '${PASSWORD}' --comment 'Vagrant User' --create-home --user-group vagrant

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Adding vagrant to wheel group"
/usr/bin/usermod -aG wheel vagrant

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Configuring sudo for vagrant"
echo 'Defaults env_keep += "SSH_AUTH_SOCK"' > /etc/sudoers.d/10_vagrant
echo 'vagrant ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/10_vagrant
/usr/bin/chmod 0440 /etc/sudoers.d/10_vagrant
/usr/bin/visudo -c

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Configuring SSH access for vagrant"
/usr/bin/install --directory --owner=vagrant --group=vagrant --mode=0700 /home/vagrant/.ssh
/usr/bin/curl --output /home/vagrant/.ssh/authorized_keys --location https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant.pub
/usr/bin/chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
/usr/bin/chmod 0600 /home/vagrant/.ssh/authorized_keys

echo ">>>> ${CONFIG_SCRIPT_SHORT}: Configuration complete"
EOF

echo ">>>> Entering chroot and configuring system"
/usr/bin/arch-chroot "${TARGET_DIR}" "${CONFIG_SCRIPT}"

echo ">>>> Removing configuration script"
rm "${TARGET_DIR}${CONFIG_SCRIPT}"

echo ">>>> install-base.sh: Completing installation.."
/usr/bin/sleep 3

/usr/bin/umount -R "${TARGET_DIR}"

echo ">>>> install-base.sh: Installation complete!"
