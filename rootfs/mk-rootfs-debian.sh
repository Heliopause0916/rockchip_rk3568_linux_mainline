#!/bin/bash

#DEB_REPO="https://deb.debian.org/debian"
DEB_REPO="https://mirrors.ustc.edu.cn/debian"
DEB_DISTRO="bookworm"
PREINSTALL_PACKAGES="nano,build-essential,ca-certificates"
OVERLAY_DIR="overlay-debian"
SOURCES_LIST_FILE="sources.list.debian"

ROOTFS_DIR="rootfs-debian"
ROOTFS_BASE_ARCHIVE="rootfs-debian-base.tar.gz"

ROOTFS_MINIMAL_ARCHIVE="rootfs-debian-minimal.tar.gz"
ROOTFS_MINIMAL_DIR="rootfs-debian-minimal"

ROOTFS_FULL_ARCHIVE="rootfs-debian-full.tar.gz"
ROOTFS_FULL_DIR="rootfs-debian-full"

ROOTFS_CUSTOM_ARCHIVE="rootfs-debian-custom.tar.gz"
ROOTFS_CUSTOM_DIR="rootfs-debian-custom"

# 构建规格开关，默认全部构建
BUILD_MINIMAL=1
BUILD_FULL=1
BUILD_CUSTOM=1

# 解析参数：可指定只构建某个规格（minimal/custom/full 三选一，互斥）
REQUESTED_MINIMAL=0
REQUESTED_CUSTOM=0
REQUESTED_FULL=0

for arg in "$@"; do
    case "$arg" in
        minimal)
            REQUESTED_MINIMAL=1
            ;;
        custom)
            REQUESTED_CUSTOM=1
            ;;
        full)
            REQUESTED_FULL=1
            ;;
        -h|--help)
            echo "用法: $0 [minimal|custom|full]"
            echo "  不带参数：构建 base + minimal + custom + full"
            echo "  minimal  ：只构建 minimal（base 按需复用或构建）"
            echo "  custom   ：构建 minimal + custom（在 minimal 基础上加 LXQt 桌面）"
            echo "  full     ：只构建 full（依赖已有的 minimal 归档）"
            echo "  说明：minimal/custom/full 三种规格互斥，一次只能指定一个"
            exit 0
            ;;
        *)
            echo "未知参数: $arg"
            exit 1
            ;;
    esac
done

# 规格互斥校验（与参数出现顺序无关）
if [ $(( REQUESTED_MINIMAL + REQUESTED_CUSTOM + REQUESTED_FULL )) -gt 1 ]; then
    echo "错误: minimal/custom/full 三种规格互斥，一次只能指定一个"
    exit 1
fi

# 依据被请求的规格设置构建开关（默认全部构建）
if [ "${REQUESTED_MINIMAL}" = "1" ]; then
    BUILD_CUSTOM=0
    BUILD_FULL=0
elif [ "${REQUESTED_CUSTOM}" = "1" ]; then
    # custom 依赖 minimal 归档，因此保留 BUILD_MINIMAL=1
    BUILD_FULL=0
elif [ "${REQUESTED_FULL}" = "1" ]; then
    BUILD_MINIMAL=0
    BUILD_CUSTOM=0
fi

if [ $(id -u) != "0" ]; then
    echo "Need root privilege to create rootfs!"
    exit 1
fi

# 确保 chroot 失败时卸载挂载
cleanup_rootfs_mounts() {
    umount -l "${ROOTFS_MINIMAL_DIR}/dev/shm" 2>/dev/null || true
    umount -l "${ROOTFS_MINIMAL_DIR}/dev/pts" 2>/dev/null || true
    umount -l "${ROOTFS_MINIMAL_DIR}/dev" 2>/dev/null || true
    umount -l "${ROOTFS_MINIMAL_DIR}/proc" 2>/dev/null || true
    umount -l "${ROOTFS_FULL_DIR}/dev/shm" 2>/dev/null || true
    umount -l "${ROOTFS_FULL_DIR}/dev/pts" 2>/dev/null || true
    umount -l "${ROOTFS_FULL_DIR}/dev" 2>/dev/null || true
    umount -l "${ROOTFS_FULL_DIR}/proc" 2>/dev/null || true
    umount -l "${ROOTFS_CUSTOM_DIR}/dev/shm" 2>/dev/null || true
    umount -l "${ROOTFS_CUSTOM_DIR}/dev/pts" 2>/dev/null || true
    umount -l "${ROOTFS_CUSTOM_DIR}/dev" 2>/dev/null || true
    umount -l "${ROOTFS_CUSTOM_DIR}/proc" 2>/dev/null || true
}
trap cleanup_rootfs_mounts EXIT

if [ ! -f "${ROOTFS_BASE_ARCHIVE}" ]; then
    echo "No base rootfs found, start building..."
    debootstrap --arch=arm64 --include="${PREINSTALL_PACKAGES}" "${DEB_DISTRO}" "${ROOTFS_DIR}" "${DEB_REPO}"
    tar --xform s:'^./':: -czpf "${ROOTFS_BASE_ARCHIVE}" --xattrs -C "${ROOTFS_DIR}" .
    echo "Base rootfs building completed."
fi

if [ "${BUILD_MINIMAL}" = "1" ] && [ ! -f "${ROOTFS_MINIMAL_ARCHIVE}" ]; then
    echo "No rootfs-minimal found, start building..."
    if [ ! -d "${ROOTFS_MINIMAL_DIR}" ]; then
        mkdir -p "${ROOTFS_MINIMAL_DIR}"
        tar -xzf "${ROOTFS_BASE_ARCHIVE}" --xattrs --xattrs-include='*' -C "${ROOTFS_MINIMAL_DIR}"
    fi

    cp /usr/bin/qemu-aarch64-static "${ROOTFS_MINIMAL_DIR}/usr/bin/"

    if [ -d "${OVERLAY_DIR}" ]; then
        cp -rf "${OVERLAY_DIR}/." "${ROOTFS_MINIMAL_DIR}/"
    fi

    cp -f "${SOURCES_LIST_FILE}" "${ROOTFS_MINIMAL_DIR}/etc/apt/sources.list"
    rm -f "${ROOTFS_MINIMAL_DIR}/etc/resolv.conf"
    cp /etc/resolv.conf "${ROOTFS_MINIMAL_DIR}/etc/resolv.conf"

    mkdir -p "${ROOTFS_MINIMAL_DIR}/dev/pts" "${ROOTFS_MINIMAL_DIR}/dev/shm"
    mount -t devtmpfs devtmpfs "${ROOTFS_MINIMAL_DIR}/dev"
    mount -t devpts devpts "${ROOTFS_MINIMAL_DIR}/dev/pts"
    mount -t tmpfs tmpfs "${ROOTFS_MINIMAL_DIR}/dev/shm"
    mount -t proc proc "${ROOTFS_MINIMAL_DIR}/proc"

    cat << EOF | chroot "${ROOTFS_MINIMAL_DIR}" /bin/bash
set -e

rm -rf /debootstrap || true

export DEBIAN_FRONTEND=noninteractive
export LANG=en_US.UTF-8

apt-get update

apt-get install -fy locales
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
echo "LANG=en_US.UTF-8" > /etc/default/locale
dpkg-reconfigure locales

useradd photonicat -m -u 1000 -s /bin/bash || true
usermod -a -G sudo photonicat
usermod -a -G video photonicat
usermod -a -G render photonicat
echo 'root:photonicat' | chpasswd
echo 'photonicat:photonicat' | chpasswd
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" >/etc/timezone
echo "photonicat-debian" >/etc/hostname
echo "127.0.0.1 localhost" >/etc/hosts
echo "127.0.1.1 photonicat-debian" >>/etc/hosts
echo "" >>/etc/hosts
echo "# The following lines are desirable for IPv6 capable hosts" >>/etc/hosts
echo "::1       localhost ip6-localhost ip6-loopback" >>/etc/hosts
echo "ff02::1   ip6-allnodes" >>/etc/hosts
echo "ff02::2   ip6-allrouters" >>/etc/hosts
echo "tmpfs /tmp tmpfs defaults,nodev,nosuid,size=512M,mode=1777 0 0" >> /etc/fstab

apt-get install -fy sudo fakeroot devscripts cmake binfmt-support dh-make \
    dh-exec device-tree-compiler bc cpio parted dosfstools mtools alsa-utils \
    libssl-dev dpkg-dev isc-dhcp-client-ddns build-essential libgpiod2 \
    libjson-c5 libusb-1.0-0 nano network-manager i2c-tools ntp git \
    usbutils pciutils htop openssh-server build-essential autotools-dev \
    meson libglib2.0-dev libjson-c-dev libgpiod-dev libusb-1.0-0-dev gdb \
    p7zip-full net-tools iotop wget firmware-linux-free firmware-linux-nonfree \
    firmware-misc-nonfree firmware-atheros firmware-iwlwifi firmware-brcm80211 \
    bridge-utils systemd-zram-generator

apt-get clean

usermod -a -G audio photonicat

rm -f /etc/resolv.conf
ln -sf ../run/NetworkManager/resolv.conf /etc/resolv.conf

EOF

    if [ ${PIPESTATUS[1]} -ne 0 ]; then
        echo "minimal chroot 执行失败，停止构建"
        exit 1
    fi

    umount -l "${ROOTFS_MINIMAL_DIR}/dev/shm" 2>/dev/null || true
    umount -l "${ROOTFS_MINIMAL_DIR}/dev/pts" 2>/dev/null || true
    umount -l "${ROOTFS_MINIMAL_DIR}/dev" 2>/dev/null || true
    umount -l "${ROOTFS_MINIMAL_DIR}/proc" 2>/dev/null || true

    tar --xform s:'^./':: -czpf "${ROOTFS_MINIMAL_ARCHIVE}" --exclude="proc/*" --exclude="dev/*" --exclude="sys/*" --exclude="run/*" --xattrs -C "${ROOTFS_MINIMAL_DIR}" .
    echo "rootfs-minimal building completed."
fi

if [ "${BUILD_CUSTOM}" = "1" ] && [ ! -f "${ROOTFS_CUSTOM_ARCHIVE}" ]; then
    if [ ! -f "${ROOTFS_MINIMAL_ARCHIVE}" ]; then
        echo "错误: 构建 custom 需要 minimal 归档 (${ROOTFS_MINIMAL_ARCHIVE})，但不存在。"
        echo "请先运行: $0 minimal"
        exit 1
    fi
    echo "No rootfs-custom found, start building..."
    if [ ! -d "${ROOTFS_CUSTOM_DIR}" ]; then
        mkdir -p "${ROOTFS_CUSTOM_DIR}"
        tar -xzf "${ROOTFS_MINIMAL_ARCHIVE}" --xattrs --xattrs-include='*' -C "${ROOTFS_CUSTOM_DIR}"
    fi

    cp -f "${SOURCES_LIST_FILE}" "${ROOTFS_CUSTOM_DIR}/etc/apt/sources.list"
    rm -f "${ROOTFS_CUSTOM_DIR}/etc/resolv.conf"
    cp /etc/resolv.conf "${ROOTFS_CUSTOM_DIR}/etc/resolv.conf"

    mkdir -p "${ROOTFS_CUSTOM_DIR}/dev/pts" "${ROOTFS_CUSTOM_DIR}/dev/shm"
    mount -t devtmpfs devtmpfs "${ROOTFS_CUSTOM_DIR}/dev"
    mount -t devpts devpts "${ROOTFS_CUSTOM_DIR}/dev/pts"
    mount -t tmpfs tmpfs "${ROOTFS_CUSTOM_DIR}/dev/shm"
    mount -t proc proc "${ROOTFS_CUSTOM_DIR}/proc"

    cat << EOF | chroot "${ROOTFS_CUSTOM_DIR}" /bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export LANG=en_US.UTF-8

apt-get install -fy lxqt lightdm lightdm-gtk-greeter qterminal \
    fonts-noto-cjk fonts-wqy-zenhei

apt-get clean

rm -f /etc/resolv.conf
ln -sf ../run/NetworkManager/resolv.conf /etc/resolv.conf

EOF

    if [ ${PIPESTATUS[1]} -ne 0 ]; then
        echo "custom chroot 执行失败，停止构建"
        exit 1
    fi

    umount -l "${ROOTFS_CUSTOM_DIR}/dev/shm" 2>/dev/null || true
    umount -l "${ROOTFS_CUSTOM_DIR}/dev/pts" 2>/dev/null || true
    umount -l "${ROOTFS_CUSTOM_DIR}/dev" 2>/dev/null || true
    umount -l "${ROOTFS_CUSTOM_DIR}/proc" 2>/dev/null || true

    tar --xform s:'^./':: -czpf "${ROOTFS_CUSTOM_ARCHIVE}" --exclude="proc/*" --exclude="dev/*" --exclude="sys/*" --exclude="run/*" --xattrs -C "${ROOTFS_CUSTOM_DIR}" .
    echo "rootfs-custom building completed."
fi

if [ "${BUILD_FULL}" = "1" ] && [ ! -f "${ROOTFS_FULL_ARCHIVE}" ]; then
    if [ ! -f "${ROOTFS_MINIMAL_ARCHIVE}" ]; then
        echo "错误: 构建 full 需要 minimal 归档 (${ROOTFS_MINIMAL_ARCHIVE})，但不存在。"
        echo "请先运行: $0 minimal"
        exit 1
    fi
    echo "No rootfs-full found, start building..."
    if [ ! -d "${ROOTFS_FULL_DIR}" ]; then
        mkdir -p "${ROOTFS_FULL_DIR}"
        tar -xzf "${ROOTFS_MINIMAL_ARCHIVE}" --xattrs --xattrs-include='*' -C "${ROOTFS_FULL_DIR}"
    fi

    cp -f "${SOURCES_LIST_FILE}" "${ROOTFS_FULL_DIR}/etc/apt/sources.list"
    rm -f "${ROOTFS_FULL_DIR}/etc/resolv.conf"
    cp /etc/resolv.conf "${ROOTFS_FULL_DIR}/etc/resolv.conf"

    mkdir -p "${ROOTFS_FULL_DIR}/dev/pts" "${ROOTFS_FULL_DIR}/dev/shm"
    mount -t devtmpfs devtmpfs "${ROOTFS_FULL_DIR}/dev"
    mount -t devpts devpts "${ROOTFS_FULL_DIR}/dev/pts"
    mount -t tmpfs tmpfs "${ROOTFS_FULL_DIR}/dev/shm"
    mount -t proc proc "${ROOTFS_FULL_DIR}/proc"

    cat << EOF | chroot "${ROOTFS_FULL_DIR}" /bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export LANG=en_US.UTF-8

apt-get install -fy pipewire pipewire-alsa pipewire-pulse pavucontrol \
    zenity gnome celluloid fonts-cantarell fonts-wqy-zenhei \
    fonts-noto-cjk ibus ibus-libpinyin ibus-gtk ibus-gtk3 \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly gstreamer1.0-tools gstreamer1.0-alsa \
    gstreamer1.0-plugins-base-apps cheese glmark2-es2 glmark2-es2-wayland \
    firefox-esr audacious gnome-shell-extensions gnome-shell-extensions-extra vlc \
    gparted

apt-get clean

usermod -a -G render Debian-gdm

rm -f /etc/resolv.conf
ln -sf ../run/NetworkManager/resolv.conf /etc/resolv.conf

EOF

    if [ ${PIPESTATUS[1]} -ne 0 ]; then
        echo "full chroot 执行失败，停止构建"
        exit 1
    fi

    umount -l "${ROOTFS_FULL_DIR}/dev/shm" 2>/dev/null || true
    umount -l "${ROOTFS_FULL_DIR}/dev/pts" 2>/dev/null || true
    umount -l "${ROOTFS_FULL_DIR}/dev" 2>/dev/null || true
    umount -l "${ROOTFS_FULL_DIR}/proc" 2>/dev/null || true

    tar --xform s:'^./':: -czpf "${ROOTFS_FULL_ARCHIVE}" --exclude="proc/*" --exclude="dev/*" --exclude="sys/*" --exclude="run/*" --xattrs -C "${ROOTFS_FULL_DIR}" .
    echo "rootfs-full building completed."
fi
