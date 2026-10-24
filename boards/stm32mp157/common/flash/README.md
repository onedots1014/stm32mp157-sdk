# STM32MP157 Flash Tool

Flash firmware to STM32MP157 boards via STM32CubeProgrammer.

## Directory Structure

```
common/flash/
├── flash.sh                              # Flash script
├── README.md
└── flash_config/
    ├── flash_config.conf                 # Programmer path, connection, profiles
    ├── Update_emmc_all.tsv               # Full system (TFA + U-Boot + kernel + rootfs)
    ├── Update_emmc_bootloader.tsv        # TFA + U-Boot only
    ├── Update_emmc_kernel.tsv            # bootfs + rootfs only
    ├── Update_emmc_rootfs.tsv            # rootfs only
    └── Update_emmc_buildroot.tsv         # Buildroot system
```

## Usage

Typically invoked through the top-level `build.sh`:

```bash
./build.sh flash                    # Flash full system (default board)
./build.sh flash kernel             # Flash kernel only
./build.sh flash bootloader         # Flash bootloader only
./build.sh flash rootfs             # Flash rootfs only
./build.sh flash buildroot          # Flash buildroot system
./build.sh flash config             # Show available profiles

./build.sh -b 100ask_stm32mp157 flash kernel   # Flash for specific board
```

Can also be invoked directly:

```bash
# Set board via environment
BOARD_NAME=100ask_stm32mp157 boards/stm32mp157/common/flash/flash.sh kernel
```

## Output Directory

The flash script reads `OUTPUT_DIR` from the environment (set by `build.sh`).
Build artifacts are expected at:

```
output/<board_name>/
├── atf/
│   ├── serialboot/tf-a-*-serialboot.stm32
│   └── trusted/tf-a-*.stm32
├── u-boot.stm32
├── bootfs.ext4
└── rootfs.ext4
```

For buildroot builds, artifacts are at `buildroot/output/images/`.

## TSV File Format

TSV files define the eMMC flash layout for STM32CubeProgrammer.
Paths use `$OUTPUT_DIR` which is resolved to an absolute path at runtime.

| Column | Description                                           |
|--------|-------------------------------------------------------|
| Opt    | `-` skip, `P` write, `PD` write after erasing        |
| Id     | Partition ID                                          |
| Name   | Partition name                                        |
| Type   | Binary / System / FileSystem                          |
| IP     | Target device (`none` for serial boot, `mmc1` for eMMC) |
| Offset | Flash offset or boot partition (`boot1`, `boot2`)     |
| Binary | File path (`$OUTPUT_DIR/...` or relative to project root) |

## Prerequisites

- [STM32CubeProgrammer](https://www.st.com/en/development-tools/stm32cubeprog.html) installed and `STM32_Programmer_CLI` in `PATH`
- Board connected via USB in DFU mode
