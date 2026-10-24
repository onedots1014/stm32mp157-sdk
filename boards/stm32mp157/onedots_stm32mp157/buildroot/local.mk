# Build these packages from the patched trees in sources/ (see
# scripts/fetch-sources.sh) instead of downloading them. Paths are relative to
# this BR2_EXTERNAL tree: boards/stm32mp157/onedots_stm32mp157/buildroot.
SDK_SOURCES = $(BR2_EXTERNAL_ONEDOTS_STM32MP157_PATH)/../../../../sources

LINUX_OVERRIDE_SRCDIR = $(SDK_SOURCES)/linux
UBOOT_OVERRIDE_SRCDIR = $(SDK_SOURCES)/u-boot
ARM_TRUSTED_FIRMWARE_OVERRIDE_SRCDIR = $(SDK_SOURCES)/tf-a
BUSYBOX_OVERRIDE_SRCDIR = $(SDK_SOURCES)/busybox
