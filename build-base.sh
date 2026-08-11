#!/bin/bash

ARCHIVE_DIR="archives"
mkdir -p archives
WORKDIR="$(pwd)"

UBOOT_VERSION="u-boot-2023.04"
KERNEL_VERSION="linux-6.12.103"

UBOOT_ARCHIVE="${UBOOT_VERSION}.tar.bz2"
KERNEL_ARCHIVE="${KERNEL_VERSION}.tar.xz"

UBOOT_SITE="https://ftp.denx.de/pub/u-boot/${UBOOT_ARCHIVE}"
KERNEL_SITE="https://cdn.kernel.org/pub/linux/kernel/v6.x/${KERNEL_ARCHIVE}"

JOBS="$(nproc)"

export ROCKCHIP_TPL="${WORKDIR}/rkbin/bin/rk35/rk3568_ddr_1332MHz_v1.21.bin"
export BL31="${WORKDIR}/rkbin/bin/rk35/rk3568_bl31_v1.44.elf"

if [ ! -f "${ARCHIVE_DIR}/${UBOOT_ARCHIVE}" ]; then
    wget -O "${ARCHIVE_DIR}/${UBOOT_ARCHIVE}" "${UBOOT_SITE}"
fi

if [ ! -f "${ARCHIVE_DIR}/${KERNEL_ARCHIVE}" ]; then
    wget -O "${ARCHIVE_DIR}/${KERNEL_ARCHIVE}" "${KERNEL_SITE}"
fi

if [ ! -d "u-boot" ]; then
    tar -xjf "${ARCHIVE_DIR}/${UBOOT_ARCHIVE}"
    mv "${UBOOT_VERSION}" u-boot

    cd "${WORKDIR}/u-boot"
    for i in "${WORKDIR}/patches/u-boot/"*; do patch -Np1 < "${i}"; done
    cd "${WORKDIR}"
fi

echo "Building u-boot..."

cd "${WORKDIR}/u-boot"
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
mkdir -p build deploy
make O=build photonicat-rk3568_defconfig
make O=build -j${JOBS}
cp -v build/idbloader.img deploy/
cp -v build/u-boot.itb deploy/
cd "${WORKDIR}"

if [ ! -d "kernel" ]; then
    tar -xJf "${ARCHIVE_DIR}/${KERNEL_ARCHIVE}"
    mv "${KERNEL_VERSION}" kernel

    cd "${WORKDIR}/kernel"
    for i in "${WORKDIR}/patches/kernel/"*; do patch -Np1 < "${i}"; done
    cp -rf "${WORKDIR}/patches/kernel-overlay/." ./

    cd "${WORKDIR}"
fi

echo "Building kernel..."

cd "${WORKDIR}/kernel"
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
mkdir -p build deploy/modules
make O=build photonicat_defconfig
make O=build Image -j${JOBS}
make O=build modules -j${JOBS}
make O=build rockchip/rk3568-photonicat.dtb
cp -v build/arch/arm64/boot/Image deploy/
cp -v build/arch/arm64/boot/dts/rockchip/rk3568-photonicat.dtb deploy/
make O=build modules_install INSTALL_MOD_PATH="${WORKDIR}/kernel/deploy/modules" INSTALL_MOD_STRIP=1
# modules_install 由内核 Makefile.modinst 在 lib/modules/${KREL}/ 下自动创建
# build -> $(CURDIR) 链接，$(CURDIR) 为宿主机绝对路径，会随 kmods.tar.gz 部署上板
# 泄露宿主机路径；此处改为指向中性路径 /usr/src/<KREL>（板上可能不存在，为 dangling 链接）。
KREL="$(cat build/include/config/kernel.release)"
rm -f "${WORKDIR}/kernel/deploy/modules/lib/modules/${KREL}/build"
ln -s "/usr/src/${KREL}" "${WORKDIR}/kernel/deploy/modules/lib/modules/${KREL}/build"
tar --owner=0 --group=0 --xform s:'^./':: -czf deploy/kmods.tar.gz -C "${WORKDIR}/kernel/deploy/modules" .
# 生成供外部模块编译（DKMS / 外置模块）所需的构建树产物。
# modules_prepare 在已 config 的 O=build 上生成 include/generated/autoconf.h、
# include/config/kernel.release 等生成头与 Module.symvers，须在 config 之后运行，
# 此处 O=build 已完成 defconfig + modules 构建，顺序合规。
make O=build modules_prepare
# 产出 UAPI 用户态内核头，安装到 deploy/headers。
make O=build headers_install INSTALL_HDR_PATH="${WORKDIR}/kernel/deploy/headers"
# 将用户态头打包为 deploy/kheaders.tar.gz。
tar --owner=0 --group=0 --xform s:'^./':: -czf deploy/kheaders.tar.gz -C "${WORKDIR}/kernel/deploy/headers" .
# 将外部模块编译所需的构建树最小集合打包为 deploy/kbuild.tar.gz。
# 取舍：不整树拷贝 build/——其中大量对象/中间产物与 kernel/ 源码重复、体积巨大；
# 外部模块编译（make -C <build> M=...）实际需要的是 build 里的生成文件 + kernel/ 源码树配合。
# rootfs 侧将来会把 kernel/ 源码摆到 /usr/src 并将 build 链接过去，本脚本只产出 build 产物。
tar --owner=0 --group=0 --xform s:'^./':: -czf deploy/kbuild.tar.gz \
    -C "${WORKDIR}/kernel/build" \
    include \
    arch/arm64/include/generated \
    Module.symvers \
    .config
cd "${WORKDIR}"

mkdir -p deploy
mkimage -A arm -O linux -T script -C none -a 0 -e 0 -d scripts/photonicat.bootscript deploy/boot.scr

cp -v u-boot/deploy/idbloader.img deploy/
cp -v u-boot/deploy/u-boot.itb deploy/
cp -v kernel/deploy/Image deploy/
cp -v kernel/deploy/rk3568-photonicat.dtb deploy/
cp -v kernel/deploy/kmods.tar.gz deploy/
cp -v kernel/deploy/kheaders.tar.gz deploy/
cp -v kernel/deploy/kbuild.tar.gz deploy/

echo "Base system builds completed."
#dd if=idbloader.img of=/dev/mmcblk0 seek=64 conv=notrunc
#dd if=u-boot.itb of=/dev/mmcblk0 seek=16384 conv=notrunc
