#!/usr/bin/env bash
# Build the Windows 11 (NTFS + ESP) baseline qcow2 for Calamares F4
# dualboot tests.
#
# Output:  baselines/win11-ntfs.qcow2  (50 GB sparse, ~12-18 GB used)
# Account: tester / tester (local admin, created by autounattend.xml)
#
# Sources:
#   - Win11 ISO: downloaded via vendored Mido.sh from Microsoft's public
#     frontend, OR a manually-placed *.iso in .cache/ (Microsoft blocks
#     automated downloads by IP, so manual placement is the common path).
#   - virtio-win.iso: Fedora's stable signed drivers ISO.
#
# ⚠ AUTOMATION CAVEAT (Windows 11 24H2/25H2) ⚠
# The new "ConX" setup engine (SetupPrep.exe) ignores autounattend.xml
# during the *windowsPE collection* phase — so product key, edition and
# disk partitioning still prompt interactively. The `specialize` and
# `oobeSystem` passes DO apply (account creation, OOBE skip, locale), so
# once you click through the first few screens the install finishes
# unattended and `tester`/`tester` is created automatically.
#
# Practical result with a 25H2 ISO: a human clicks ~5 screens (no product
# key → edition → accept EULA → custom install → pick the unallocated
# disk), then walks away. The disk layout is then Windows' default (ESP
# ~100 MB), NOT the 512 MiB we'd coordinate with Debian — fine for
# Windows-only T3 tests; the F4 dualboot merge reconciles ESPs anyway.
#
# TO MAKE IT FULLY UNATTENDED (future work): force the legacy setup.exe
# by injecting into the install ISO's sources/boot.wim (image 2) the
# registry value  [HKLM\SYSTEM\Setup] "CmdLine"="X:\sources\setup.exe".
# The legacy setup honours autounattend.xml in windowsPE too. Needs a
# registry-hive editor (hivex/chntpw, not installed here) and careful
# testing — the CmdLine override is reportedly fragile when combined with
# a rich answer file. See elevenforum.com threads on "W11 25H2
# autounattend.xml fails / integrate legacy setup".
#
# Runtime: ~25-45 min on a modern host (mostly Windows OOBE phase).

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$ROOT_DIR/.cache"
BASELINES_DIR="$ROOT_DIR/baselines"
LOGS_DIR="$ROOT_DIR/logs"
OVMF_CODE="$ROOT_DIR/ovmf/OVMF_CODE.4m.fd"
OVMF_VARS_TEMPLATE="$ROOT_DIR/ovmf/OVMF_VARS-template.4m.fd"
MIDO="$SCRIPT_DIR/vendor/Mido.sh"

BASELINE_NAME="win11-ntfs"
WIN_VARIANT="${WIN_VARIANT:-win11x64-enterprise-eval}"
DISK_SIZE="${DISK_SIZE:-50G}"
VIRTIO_URL="${VIRTIO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"

err()  { echo "ERROR: $*" >&2; exit 1; }
log()  { printf '>>> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--force] [--remove-iso] [--variant NAME]

Builds baselines/$BASELINE_NAME.qcow2 unattended.

  --force           Overwrite existing baseline (default: refuse)
  --remove-iso      Delete cached ISOs after build (default: keep)
  --variant NAME    Mido edition: win11x64, win11x64-enterprise-eval (default)
  -h, --help        This help

Env overrides:
  DISK_SIZE         Default: 50G
  WIN_VARIANT       Default: win11x64-enterprise-eval (no key required)
  VIRTIO_URL        Default: fedorapeople.org/.../stable-virtio/virtio-win.iso
  DISPLAY_MODE      QEMU -display backend. Default: none (headless).
                    Set gtk or sdl to watch/debug the install visually.
USAGE
}

FORCE=0
REMOVE_ISO=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force)      FORCE=1 ;;
        --remove-iso) REMOVE_ISO=1 ;;
        --variant)    WIN_VARIANT="$2"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            err "Unknown argument: $1" ;;
    esac
    shift
done

TARGET_BASELINE="$BASELINES_DIR/$BASELINE_NAME.qcow2"
if [ -f "$TARGET_BASELINE" ] && [ "$FORCE" != "1" ]; then
    err "$TARGET_BASELINE already exists. Use --force to overwrite."
fi

for tool in qemu-img qemu-system-x86_64 xorriso curl sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || err "Missing tool: $tool"
done
[ -r "$OVMF_CODE" ]          || err "OVMF_CODE not found at $OVMF_CODE"
[ -r "$OVMF_VARS_TEMPLATE" ] || err "OVMF_VARS template not found at $OVMF_VARS_TEMPLATE"
[ -x "$MIDO" ]               || err "Mido.sh not found/executable at $MIDO"

mkdir -p "$CACHE_DIR" "$BASELINES_DIR" "$LOGS_DIR"

# ---------------------------------------------------------------------------
# 1. virtio-win.iso (drivers Microsoft never ships natively).
# ---------------------------------------------------------------------------
VIRTIO_ISO="$CACHE_DIR/virtio-win.iso"
if [ ! -f "$VIRTIO_ISO" ]; then
    log "Downloading virtio-win.iso (~600 MB) — first run only..."
    curl -fL --silent --show-error -o "$VIRTIO_ISO" "$VIRTIO_URL"
else
    log "virtio-win.iso cached at $VIRTIO_ISO ($(stat -c %s "$VIRTIO_ISO" | numfmt --to=iec))"
fi

# ---------------------------------------------------------------------------
# 2. Windows ISO — prefer an already-present .iso in .cache/, fall back to
#    downloading via Mido. We match permissively (any *.iso whose name
#    contains "win" + "11" case-insensitive) so manually-downloaded ISOs
#    from microsoft.com — like Win11_<ver>_<lang>_x64.iso — work without
#    renaming, and follow symlinks so the user can point at ~/Downloads.
# ---------------------------------------------------------------------------
WIN_ISO=$(find -L "$CACHE_DIR" -maxdepth 1 -type f -iname '*win*11*.iso' 2>/dev/null | head -1)
if [ -n "$WIN_ISO" ]; then
    log "Windows ISO found at $WIN_ISO ($(stat -L -c %s "$WIN_ISO" | numfmt --to=iec))"
else
    log "No Windows ISO in cache — attempting Mido download ($WIN_VARIANT, ~5.4 GB)..."
    log "(If Microsoft blocks the automated request, place a .iso manually at"
    log " $CACHE_DIR/ and re-run. Symlinks are followed.)"
    ( cd "$CACHE_DIR" && "$MIDO" "$WIN_VARIANT" ) \
        || err "Mido download failed. Download the ISO from https://www.microsoft.com/software-download/windows11 in a browser and drop it in $CACHE_DIR/"
    WIN_ISO=$(find -L "$CACHE_DIR" -maxdepth 1 -type f -iname '*win*11*.iso' 2>/dev/null | head -1) \
        || err "Mido finished but no Windows ISO found in $CACHE_DIR"
fi

# ---------------------------------------------------------------------------
# 3. Workspace + autounattend.xml + virtio-driver-aware unattend mini-ISO.
# ---------------------------------------------------------------------------
# Workspace under .cache/ (on /home, ~300 GB) not /tmp — the ISO remaster
# extracts ~8 GB and tmpfs is only 31 GB.
WORK=$(mktemp -d "$CACHE_DIR/win-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# The autounattend.xml below:
#  - bypasses Win11 hardware checks (TPM/SecureBoot/RAM/CPU/Storage) via
#    HKLM\SYSTEM\Setup\LabConfig — these are the canonical reg keys that
#    have shipped since the original Win11 release and remain effective.
#  - declares a virtio-win driver path (E:\) for the Windows setup phase
#    so it can see the virtio-block disk.
#  - partitions: ESP 512 MiB + MSR 16 MiB + NTFS C: rest (Microsoft's
#    recommended layout — matches what a UEFI dualboot expects).
#  - creates a local "tester" admin account (no Microsoft account screen
#    via BypassNRO + Skip*OOBE flags).
#  - autologs into tester on first boot and immediately runs
#    `shutdown /s /t 0`, so QEMU exits via ACPI power-off and we can
#    detect a clean end-of-install.
cat > "$WORK/autounattend.xml" <<'AUTOUNATTEND'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SetupUILanguage>
        <UILanguage>es-ES</UILanguage>
      </SetupUILanguage>
      <InputLocale>es-ES</InputLocale>
      <SystemLocale>es-ES</SystemLocale>
      <UILanguage>es-ES</UILanguage>
      <UserLocale>es-ES</UserLocale>
    </component>

    <component name="Microsoft-Windows-PnpCustomizationsWinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1">
          <Path>E:\viostor\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2">
          <Path>E:\NetKVM\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3">
          <Path>E:\vioscsi\w11\amd64</Path>
        </PathAndCredentials>
      </DriverPaths>
    </component>

    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>

      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>512</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>16</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>System</Label>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order>
              <PartitionID>3</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>

      <ImageInstall>
        <OSImage>
          <!-- Skip the edition picker that consumer multi-edition ISOs show.
               Edition names are typically English even on localized ISOs;
               if the ISO ships only Home, change to "Windows 11 Home". -->
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/NAME</Key>
              <Value>Windows 11 Pro</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>

      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Tester</FullName>
        <Organization>AmiCachy</Organization>
      </UserData>
    </component>
  </settings>

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>WIN11-BASELINE</ComputerName>
      <RegisteredOwner>Tester</RegisteredOwner>
      <RegisteredOrganization>AmiCachy</RegisteredOrganization>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password>
              <Value>tester</Value>
              <PlainText>true</PlainText>
            </Password>
            <Description>AmiCachy test user</Description>
            <DisplayName>Tester</DisplayName>
            <Group>Administrators</Group>
            <Name>tester</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Password>
          <Value>tester</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>tester</Username>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Home</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Power off after first logon — signals build done</Description>
          <CommandLine>shutdown /s /t 0</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>

    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
  </settings>

</unattend>
AUTOUNATTEND

# Remaster the install ISO with autounattend.xml at its filesystem root +
# a non-interactive UEFI boot image. Two reasons a secondary unattend CD
# was abandoned:
#  - Win11 24H2/25H2's new setup engine only reads autounattend.xml from
#    the *boot* medium root, not from a secondary CD volume (confirmed by
#    the installer prompting for product key/edition when it was on a
#    separate CD).
#  - The stock ISO's El-Torito EFI image stops at "Press any key to boot
#    from CD"; efisys_noprompt.bin (shipped in the ISO) boots silently.
# Result is cached so re-runs skip the ~1 min extract+repack.
AMICACHY_ISO="$CACHE_DIR/$(basename "${WIN_ISO%.iso}")-amicachy.iso"
if [ -f "$AMICACHY_ISO" ] && [ "$FORCE" != "1" ]; then
    log "AmiCachy install ISO cached: $AMICACHY_ISO"
else
    log "Remastering install ISO (extract + inject autounattend + noprompt EFI)..."
    ISO_ROOT="$WORK/iso-root"
    mkdir -p "$ISO_ROOT"
    # 7z reads the UDF volume; xorriso -indev only sees the ISO9660 bridge stub.
    7z x -y -o"$ISO_ROOT" "$WIN_ISO" >/dev/null 2>&1 || err "ISO extract failed"
    [ -f "$ISO_ROOT/efi/microsoft/boot/efisys_noprompt.bin" ] \
        || err "efisys_noprompt.bin not present in ISO — cannot make non-interactive UEFI boot"
    cp "$WORK/autounattend.xml" "$ISO_ROOT/autounattend.xml"
    # iso-level 4 (ISO9660 v2) carries install.wim >4 GB without UDF, which
    # xorriso 1.5.8 can't author. Windows setup reads either fine.
    xorriso -as mkisofs \
        -iso-level 4 -joliet -joliet-long -rational-rock \
        -volid "WIN11_AMICACHY" \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-boot boot/etfsboot.com -eltorito-platform 0x00 \
        -eltorito-alt-boot \
        -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot -eltorito-platform 0xef \
        -o "$AMICACHY_ISO" \
        "$ISO_ROOT/" 2>&1 | tail -3
    [ -f "$AMICACHY_ISO" ] || err "ISO remaster failed"
    rm -rf "$ISO_ROOT"
    log "AmiCachy install ISO ready: $AMICACHY_ISO ($(stat -c %s "$AMICACHY_ISO" | numfmt --to=iec))"
fi

# ---------------------------------------------------------------------------
# 4. Fresh empty qcow2 + per-build OVMF VARS.
# ---------------------------------------------------------------------------
TARGET_DISK="$WORK/disk.qcow2"
log "Creating empty disk: $DISK_SIZE qcow2"
qemu-img create -f qcow2 "$TARGET_DISK" "$DISK_SIZE" >/dev/null

OVMF_VARS_RUN="$WORK/OVMF_VARS-build.4m.fd"
cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_RUN"

LOG_FILE="$LOGS_DIR/build-$BASELINE_NAME-$(date +%Y%m%d-%H%M%S).serial.log"

# ---------------------------------------------------------------------------
# 5. Launch QEMU. Two CD-ROMs: the AmiCachy install ISO (boots + carries
#    autounattend.xml at root) and virtio-win (storage/net drivers). Disk
#    on virtio-blk; setup loads viostor.sys from the virtio CD in the
#    windowsPE pass via PnpCustomizationsWinPE before partitioning.
# ---------------------------------------------------------------------------
log "Launching Windows installer (${DISPLAY_MODE:-headless}, ~25-45 min total)"
log "Serial log: $LOG_FILE"
log "Disk:       $TARGET_DISK (will move to baselines/ on success)"

set +e
# Wall-clock cap 75m (worst case OOBE + WinSAT) → SIGTERM + 1m SIGKILL grace.
# No -no-reboot: Windows setup reboots several times (expand image → OOBE);
# QEMU must survive those resets and only exit on the final `shutdown /s`
# (ACPI power-off) from FirstLogonCommands.
#
# Boot order matters: the disk gets bootindex=1, the install ISO bootindex=2.
# Because efisys_noprompt boots the CD with no keypress, giving the CD
# precedence would re-launch setup on every reboot (infinite loop). With the
# disk first: boot 1 finds it empty and falls through to the CD; after the
# image is applied the disk is bootable and the CD is never touched again.
# CD-ROMs sit on an explicit AHCI controller (q35's `if=ide` shim is legacy
# IDE that times out on multi-GB media). usb-tablet gives a usable
# absolute-position cursor when DISPLAY_MODE is a visible backend (gtk/sdl).
timeout --kill-after=60s 75m \
qemu-system-x86_64 \
    -name "build-$BASELINE_NAME" \
    -machine q35,accel=kvm -cpu host -smp 4 -m 8G \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_RUN" \
    -drive id=osdisk,file="$TARGET_DISK",format=qcow2,if=none,cache=writeback \
    -device virtio-blk-pci,drive=osdisk,bootindex=1 \
    -device ahci,id=ahci0 \
    -drive id=wincd,file="$AMICACHY_ISO",format=raw,if=none,readonly=on \
    -device ide-cd,drive=wincd,bus=ahci0.0,bootindex=2 \
    -drive id=viocd,file="$VIRTIO_ISO",format=raw,if=none,readonly=on \
    -device ide-cd,drive=viocd,bus=ahci0.1,bootindex=98 \
    -device usb-ehci,id=usb -device usb-tablet,bus=usb.0 \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -display "${DISPLAY_MODE:-none}" \
    -serial "file:$LOG_FILE"
QEMU_EXIT=$?
set -e

if [ "$QEMU_EXIT" = "124" ]; then
    err "Build hit 75m timeout — Windows setup likely stuck. See $LOG_FILE"
elif [ "$QEMU_EXIT" != "0" ]; then
    warn "QEMU exited with status $QEMU_EXIT — inspect $LOG_FILE"
    err "Build aborted"
fi

# Content sanity check: a fresh Win11 install is ~12-18 GB physical.
# An empty 50G qcow2 is ~200 KB. Anything under 6 GB means setup never
# fully completed (driver miss, autounattend parse error, …).
DISK_PHYSICAL=$(stat -c %s "$TARGET_DISK")
MIN_REASONABLE=$((6 * 1024 * 1024 * 1024))
if [ "$DISK_PHYSICAL" -lt "$MIN_REASONABLE" ]; then
    err "Resulting disk is only $(numfmt --to=iec "$DISK_PHYSICAL") — install did not complete. Inspect $LOG_FILE"
fi

# ---------------------------------------------------------------------------
# 6. Move into place.
# ---------------------------------------------------------------------------
log "Moving baseline → $TARGET_BASELINE"
mv "$TARGET_DISK" "$TARGET_BASELINE"

if [ "$REMOVE_ISO" = "1" ]; then
    log "Removing cached ISOs"
    rm -f "$WIN_ISO" "$VIRTIO_ISO"
fi

log "DONE."
log "  Baseline: $TARGET_BASELINE"
log "  Size:     $(stat -c %s "$TARGET_BASELINE" | numfmt --to=iec)"
log "  Log:      $LOG_FILE"
log ""
log "Smoke-test it manually with:"
log "    qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp 2 -m 4G \\"
log "        -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \\"
log "        -drive if=pflash,format=raw,file=<copy-of-OVMF_VARS-template> \\"
log "        -drive file=$TARGET_BASELINE,format=qcow2,if=virtio,snapshot=on \\"
log "        -boot c -display gtk -netdev user,id=net0 -device virtio-net-pci,netdev=net0"
