#!/bin/bash

DEB_REPO="http://mirrors.ustc.edu.cn/ubuntu-ports"
DEB_DISTRO="noble"
PREINSTALL_PACKAGES="nano,build-essential"
OVERLAY_DIR="overlay-ubuntu"
SOURCES_LIST_FILE="sources.list.ubuntu"

# RKNN(NPU) 闭源运行时素材目录：librknnrt.so 为闭源二进制，不能 git 入 GPL 仓库。
# 由用户在构建时通过环境变量 RKNN_ASSET_DIR 提供，目录结构约定：
#   ${RKNN_ASSET_DIR}/aarch64/librknnrt.so
#   ${RKNN_ASSET_DIR}/include/*.h   (rknn_api.h、rknn_matmul_api.h 等)
# 为空或缺少 aarch64/include 子目录时，跳过 NPU 安装并打印警告，不阻塞其余构建。
RKNN_ASSET_DIR="${RKNN_ASSET_DIR:-}"

ROOTFS_DIR="rootfs-ubuntu"
ROOTFS_BASE_ARCHIVE="rootfs-ubuntu-base.tar.gz"

ROOTFS_MINIMAL_ARCHIVE="rootfs-ubuntu-minimal.tar.gz"
ROOTFS_MINIMAL_DIR="rootfs-ubuntu-minimal"

ROOTFS_FULL_ARCHIVE="rootfs-ubuntu-full.tar.gz"
ROOTFS_FULL_DIR="rootfs-ubuntu-full"

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
}
trap cleanup_rootfs_mounts EXIT

if [ ! -f "${ROOTFS_BASE_ARCHIVE}" ]; then
    echo "No base rootfs found, start building..."
    debootstrap --arch=arm64 --include="${PREINSTALL_PACKAGES}" "${DEB_DISTRO}" "${ROOTFS_DIR}" "${DEB_REPO}"
    tar --xform s:'^./':: -czpf "${ROOTFS_BASE_ARCHIVE}" --xattrs -C "${ROOTFS_DIR}" .
    echo "Base rootfs building completed."
fi

if [ ! -f "${ROOTFS_MINIMAL_ARCHIVE}" ]; then
    echo "No rootfs-minimal found, start building..."
    if [ ! -d "${ROOTFS_MINIMAL_DIR}" ]; then
        mkdir -p "${ROOTFS_MINIMAL_DIR}"
        tar -xzf "${ROOTFS_BASE_ARCHIVE}" --xattrs --xattrs-include='*' -C "${ROOTFS_MINIMAL_DIR}"
    fi

    cp /usr/bin/qemu-aarch64-static "${ROOTFS_MINIMAL_DIR}/usr/bin/"

    if [ -d "${OVERLAY_DIR}" ]; then
        cp -rf "${OVERLAY_DIR}/." "${ROOTFS_MINIMAL_DIR}/"
    fi

    # 暂存 RKNN 闭源运行时到 chroot 目录（chroot 内无法访问宿主机 ${RKNN_ASSET_DIR}，
    # 故先在宿主机侧拷入暂存，再由下方 heredoc 段 install 到最终位置并清理）
    if [ -n "${RKNN_ASSET_DIR}" ] && [ -d "${RKNN_ASSET_DIR}/aarch64" ] && [ -d "${RKNN_ASSET_DIR}/include" ]; then
        echo "准备 RKNN 闭源运行时（librknnrt.so）+ 头文件到 chroot 暂存：${RKNN_ASSET_DIR}"
        rm -rf "${ROOTFS_MINIMAL_DIR}/opt/rknn-asset"
        mkdir -p "${ROOTFS_MINIMAL_DIR}/opt/rknn-asset/aarch64" "${ROOTFS_MINIMAL_DIR}/opt/rknn-asset/include"
        cp -f "${RKNN_ASSET_DIR}/aarch64/librknnrt.so" "${ROOTFS_MINIMAL_DIR}/opt/rknn-asset/aarch64/"
        cp -rf "${RKNN_ASSET_DIR}/include"/. "${ROOTFS_MINIMAL_DIR}/opt/rknn-asset/include/"
    else
        echo "警告：RKNN_ASSET_DIR 未设置或缺少 aarch64/include 子目录，跳过 NPU(RKNN) 运行时安装"
    fi

    cp -f "${SOURCES_LIST_FILE}" "${ROOTFS_MINIMAL_DIR}/etc/apt/sources.list"
    rm -f "${ROOTFS_MINIMAL_DIR}/etc/resolv.conf"
    cp /etc/resolv.conf "${ROOTFS_MINIMAL_DIR}/etc/resolv.conf"

    mount -t devtmpfs devtmpfs "${ROOTFS_MINIMAL_DIR}/dev"
    mount -t devpts devpts "${ROOTFS_MINIMAL_DIR}/dev/pts"
    mount -t tmpfs tmpfs "${ROOTFS_MINIMAL_DIR}/dev/shm"
    mount -t proc proc "${ROOTFS_MINIMAL_DIR}/proc"

    cat << EOF | chroot "${ROOTFS_MINIMAL_DIR}" /bin/bash

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
echo "photonicat-ubuntu" >/etc/hostname
echo "127.0.0.1 localhost" >/etc/hosts
echo "127.0.1.1 photonicat-ubuntu" >>/etc/hosts
echo "" >>/etc/hosts
echo "# The following lines are desirable for IPv6 capable hosts" >>/etc/hosts
echo "::1       localhost ip6-localhost ip6-loopback" >>/etc/hosts
echo "ff02::1   ip6-allnodes" >>/etc/hosts
echo "ff02::2   ip6-allrouters" >>/etc/hosts

apt-get install -fy sudo fakeroot devscripts cmake binfmt-support dh-make \
    dh-exec device-tree-compiler bc cpio parted dosfstools mtools alsa-utils \
    libssl-dev dpkg-dev isc-dhcp-client-ddns build-essential libgpiod2 \
    libjson-c5 libusb-1.0-0 nano network-manager i2c-tools git \
    usbutils pciutils htop openssh-server build-essential autotools-dev \
    meson libglib2.0-dev libjson-c-dev libgpiod-dev libusb-1.0-0-dev gdb \
    p7zip-full net-tools iotop wget linux-firmware

apt-get clean

usermod -a -G audio photonicat

# 安装 RKNN 闭源运行时（仅当宿主机暂存了素材时执行；闭源 blob 由用户预下载、不入仓库）
if [ -d /opt/rknn-asset ]; then
    echo "安装 RKNN librknnrt.so 到 /usr/lib ..."
    install -D -m 0644 /opt/rknn-asset/aarch64/librknnrt.so /usr/lib/librknnrt.so
    mkdir -p /usr/include/rknn
    install -m 0644 /opt/rknn-asset/include/*.h /usr/include/rknn/
    echo "/usr/lib" > /etc/ld.so.conf.d/rknn.conf
    ldconfig
    usermod -a -G render photonicat || true
    rm -rf /opt/rknn-asset
fi

rm -f /etc/resolv.conf
ln -sf ../run/NetworkManager/resolv.conf /etc/resolv.conf

EOF

    umount -l "${ROOTFS_MINIMAL_DIR}/dev"
    umount -l "${ROOTFS_MINIMAL_DIR}/proc"

    tar --xform s:'^./':: -czpf "${ROOTFS_MINIMAL_ARCHIVE}" --exclude="proc/*" --exclude="dev/*" --exclude="sys/*" --exclude="run/*" --xattrs -C "${ROOTFS_MINIMAL_DIR}" .
    echo "rootfs-minimal building completed."
fi


if [ ! -f "${ROOTFS_FULL_ARCHIVE}" ]; then
    echo "No rootfs-full found, start building..."
    if [ ! -d "${ROOTFS_FULL_DIR}" ]; then
        mkdir -p "${ROOTFS_FULL_DIR}"
        tar -xzf "${ROOTFS_MINIMAL_ARCHIVE}" --xattrs --xattrs-include='*' -C "${ROOTFS_FULL_DIR}"
    fi

    cp -f "${SOURCES_LIST_FILE}" "${ROOTFS_FULL_DIR}/etc/apt/sources.list"
    rm -f "${ROOTFS_FULL_DIR}/etc/resolv.conf"
    cp /etc/resolv.conf "${ROOTFS_FULL_DIR}/etc/resolv.conf"

    mount -t devtmpfs devtmpfs "${ROOTFS_FULL_DIR}/dev"
    mount -t devpts devpts "${ROOTFS_FULL_DIR}/dev/pts"
    mount -t tmpfs tmpfs "${ROOTFS_FULL_DIR}/dev/shm"
    mount -t proc proc "${ROOTFS_FULL_DIR}/proc"

    cat << EOF | chroot "${ROOTFS_FULL_DIR}" /bin/bash

export DEBIAN_FRONTEND=noninteractive
export LANG=en_US.UTF-8

apt-get install -fy pipewire pipewire-pulse pavucontrol \
    zenity ubuntu-gnome-desktop gnome celluloid fonts-cantarell fonts-wqy-zenhei \
    fonts-noto-cjk ibus ibus-libpinyin ibus-gtk ibus-gtk3 \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly gstreamer1.0-tools gstreamer1.0-alsa \
    gstreamer1.0-plugins-base-apps cheese glmark2-es2 glmark2-es2-wayland \
    firefox audacious gnome-shell-extensions vlc gparted

apt-get clean

usermod -a -G render gdm
touch /usr/share/pipewire/media-session.d/with-pulseaudio

rm -f /etc/resolv.conf
ln -sf ../run/NetworkManager/resolv.conf /etc/resolv.conf

EOF

    umount -l "${ROOTFS_FULL_DIR}/dev"
    umount -l "${ROOTFS_FULL_DIR}/proc"

    tar --xform s:'^./':: -czpf "${ROOTFS_FULL_ARCHIVE}" --exclude="proc/*" --exclude="dev/*" --exclude="sys/*" --exclude="run/*" --xattrs -C "${ROOTFS_FULL_DIR}" .
    echo "rootfs-full building completed."
fi
