"""Installation backend — shell command sequences for system deployment.

All disk operations, live-system cloning, chroot configuration, and bootloader
setup are encapsulated here. Every command runs through CommandRunner
for consistent logging and error handling.
"""

import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Callable

from .resources import (
    AMIGA_DIRS,
    BOOT_ENTRIES,
    INSTALLER_DATA_DIR,
    INSTALL_LOG_PATH,
    LOADER_CONF_TEMPLATE,
    MOUNTPOINT,
)

ROM_SUFFIXES = {".rom", ".key", ".bin"}
BOOT_MEDIA_SKIP_DIRS = {
    "arch",
    "boot",
    "efi",
    "loader",
    "[boot]",
    "system volume information",
}


class InstallError(Exception):
    """Base exception for installation failures."""

    def __init__(self, message: str, step: str = "", recoverable: bool = False):
        super().__init__(message)
        self.step = step
        self.recoverable = recoverable


class CommandRunner:
    """Runs shell commands with real-time output streaming."""

    def __init__(self, log_callback: Callable[[str], None]):
        self.log = log_callback
        self._log_file = open(INSTALL_LOG_PATH, "a")

    def close(self):
        self._log_file.close()

    def _write_log(self, line: str) -> None:
        self.log(line)
        self._log_file.write(line + "\n")
        self._log_file.flush()

    def run(
        self,
        cmd: list[str],
        check: bool = True,
        env: dict | None = None,
    ) -> subprocess.CompletedProcess:
        """Run a command, streaming stdout/stderr line by line."""
        self._write_log(f">>> {' '.join(cmd)}")
        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)
        # Prevent interactive GPG prompts under Cage
        merged_env["DISPLAY"] = ""
        merged_env.pop("GPG_TTY", None)

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=merged_env,
        )
        output_lines: list[str] = []
        for line in proc.stdout:
            line = line.rstrip("\n")
            output_lines.append(line)
            self._write_log(line)
        proc.wait()

        if check and proc.returncode != 0:
            raise InstallError(
                f"Command failed (exit {proc.returncode}): {' '.join(cmd)}"
            )
        return subprocess.CompletedProcess(
            cmd, proc.returncode, "\n".join(output_lines), ""
        )

    def run_chroot(
        self, cmd: list[str], check: bool = True
    ) -> subprocess.CompletedProcess:
        """Run a command inside arch-chroot at MOUNTPOINT."""
        return self.run(["arch-chroot", MOUNTPOINT] + cmd, check=check)


def _write_file(path: str, content: str) -> None:
    """Write content to a file, creating parent directories."""
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(content)


def _device_children(device: str) -> list[str]:
    """Return child partitions for a disk device."""
    try:
        result = subprocess.run(
            ["lsblk", "-nr", "-o", "PATH", device],
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        )
    except (subprocess.SubprocessError, FileNotFoundError):
        return []

    devices = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return [path for path in devices if path != device]


def _unmount_device(runner: CommandRunner, device: str) -> None:
    """Unmount anything mounted from a block device."""
    runner.run(["timeout", "3", "udisksctl", "unmount", "-b", device], check=False)
    runner.run(["umount", "-l", device], check=False)

    mountpoints: set[str] = set()
    try:
        result = subprocess.run(
            ["findmnt", "-nr", "-o", "TARGET", "--source", device],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (subprocess.SubprocessError, FileNotFoundError):
        result = None

    if result:
        mountpoints.update(line.strip() for line in result.stdout.splitlines() if line.strip())

    try:
        result = subprocess.run(
            ["lsblk", "-nr", "-o", "MOUNTPOINTS", device],
            capture_output=True,
            text=True,
            timeout=10,
        )
        mountpoints.update(line.strip() for line in result.stdout.splitlines() if line.strip())
    except (subprocess.SubprocessError, FileNotFoundError):
        pass

    for mountpoint in sorted(mountpoints, key=len, reverse=True):
        runner.run(["umount", "-R", "-l", mountpoint], check=False)
        runner.run(["umount", "-l", mountpoint], check=False)


def release_install_target(runner: CommandRunner, device: str, include_children: bool = False) -> None:
    """Stop automounters and release the selected install target."""
    runner.run(["pkill", "-x", "udiskie"], check=False)
    runner.run(["pkill", "-f", "dbus-run-session.*udiskie"], check=False)
    runner.run(["swapoff", device], check=False)

    targets = [device]
    if include_children:
        targets.extend(_device_children(device))

    for target in sorted(set(targets), key=len, reverse=True):
        _unmount_device(runner, target)
        runner.run(["swapoff", target], check=False)
        runner.run(["blockdev", "--flushbufs", target], check=False)


def clear_filesystem_signatures(runner: CommandRunner, device: str) -> None:
    """Best-effort wipefs with diagnostics; formatting can still proceed."""
    runner.run(["lsblk", "-f", device], check=False)
    result = runner.run(["wipefs", "--all", "--force", device], check=False)
    if result.returncode != 0:
        runner.run(["fuser", "-vm", device], check=False)
        runner.run(["umount", "-l", device], check=False)
        runner.run(["blockdev", "--flushbufs", device], check=False)
        result = runner.run(["wipefs", "--all", "--force", device], check=False)
    if result.returncode != 0:
        runner.run(["bash", "-c", f"echo 'WARNING: wipefs failed on {device}; continuing with forced mkfs.'"], check=False)


def format_ext4(runner: CommandRunner, device: str, label: str) -> None:
    """Create an ext4 filesystem, aggressively releasing stale holders first."""
    release_install_target(runner, device)
    result = runner.run(["mkfs.ext4", "-F", "-L", label, device], check=False)
    if result.returncode == 0:
        return

    runner.run(["lsblk", "-f", device], check=False)
    runner.run(["findmnt", "-R", device], check=False)
    runner.run(["fuser", "-vm", device], check=False)
    release_install_target(runner, device)
    runner.run(["mkfs.ext4", "-F", "-F", "-L", label, device])


def recreate_partition(runner: CommandRunner, disk: str, partition: str) -> str:
    """Delete and recreate a selected partition in the same sector range."""
    part_name = Path(partition).name
    match = re.search(r"(?:p)?(\d+)$", part_name)
    if not match:
        raise InstallError(f"Could not determine partition number for {partition}")

    part_num = match.group(1)
    start_path = Path(f"/sys/class/block/{part_name}/start")
    size_path = Path(f"/sys/class/block/{part_name}/size")
    if not start_path.exists() or not size_path.exists():
        raise InstallError(f"Could not read sector range for {partition}")

    start = start_path.read_text().strip()
    size = size_path.read_text().strip()
    end = str(int(start) + int(size) - 1)

    if not start or not end:
        raise InstallError(f"Could not find partition {part_num} on {disk}")

    runner.run(["bash", "-c", f"echo 'Recreating {partition} in-place: {start}s-{end}s'"], check=False)
    release_install_target(runner, partition)
    result = runner.run([
        "sgdisk",
        f"--delete={part_num}",
        f"--new={part_num}:{start}:{end}",
        f"--change-name={part_num}:AMICACHY",
        f"--typecode={part_num}:8300",
        disk,
    ], check=False)
    if result.returncode != 0:
        runner.run(["parted", "-s", disk, "rm", part_num])
        runner.run(["partprobe", disk], check=False)
        time.sleep(1)
        runner.run(["parted", "-s", disk, "unit", "s", "mkpart", "AMICACHY", "ext4", f"{start}s", f"{end}s"])
    runner.run(["partprobe", disk], check=False)
    runner.run(["udevadm", "settle"], check=False)
    time.sleep(1)
    return partition


# ---------------------------------------------------------------------------
# Installation steps
# ---------------------------------------------------------------------------


def partition_disk(runner: CommandRunner, device: str) -> dict[str, str]:
    """Create GPT partition table with EFI, Root, and Data partitions."""
    release_install_target(runner, device, include_children=True)
    # clear_filesystem_signatures(runner, device) # Removed to prevent accidental data loss on multi-partition disks
    runner.run(["parted", "-s", device, "mklabel", "gpt"])

    # EFI: 512 MiB
    runner.run(
        ["parted", "-s", device, "mkpart", "EFI", "fat32", "1MiB", "513MiB"]
    )
    runner.run(["parted", "-s", device, "set", "1", "esp", "on"])

    # Root: from 513MiB to 60% of disk
    runner.run(
        ["parted", "-s", device, "mkpart", "AMICACHY", "ext4", "513MiB", "60%"]
    )

    # Data: remainder
    runner.run(
        ["parted", "-s", device, "mkpart", "AMIGADATA", "ext4", "60%", "100%"]
    )

    # Determine partition device paths (nvme vs sata naming)
    sep = "p" if ("nvme" in device or "mmcblk" in device) else ""
    partitions = {
        "efi": f"{device}{sep}1",
        "root": f"{device}{sep}2",
        "data": f"{device}{sep}3",
    }

    # Wait for kernel to register new partitions
    runner.run(["partprobe", device])
    time.sleep(1)

    # Format
    runner.run(["mkfs.fat", "-F", "32", "-n", "AMIEFI", partitions["efi"]])
    format_ext4(runner, partitions["root"], "AMICACHY")
    format_ext4(runner, partitions["data"], "AMIGADATA")

    return partitions


def mount_filesystems(runner: CommandRunner, partitions: dict[str, str]) -> None:
    """Mount root, EFI, and data partitions under MOUNTPOINT."""
    runner.run(["mkdir", "-p", MOUNTPOINT])
    runner.run(["umount", "-R", MOUNTPOINT], check=False)
    runner.run(["mount", partitions["root"], MOUNTPOINT])
    runner.run(["mkdir", "-p", f"{MOUNTPOINT}/boot"])
    runner.run(["mount", partitions["efi"], f"{MOUNTPOINT}/boot"])

    amiga_data_dir = f"{MOUNTPOINT}/home/amiga/Amiga"
    runner.run(["mkdir", "-p", amiga_data_dir])
    if partitions.get("data") != "INTERNAL":
        runner.run(["mount", partitions["data"], amiga_data_dir])


def copy_live_system(runner: CommandRunner) -> None:
    """Install AmiCachy offline by cloning the running live system to disk."""
    excludes = [
        "/boot/*",
        "/dev/*",
        "/proc/*",
        "/sys/*",
        "/run/*",
        "/tmp/*",
        "/mnt/*",
        "/media/*",
        "/lost+found",
        "/var/cache/pacman/pkg/*",
        "/var/lib/pacman/sync/*",
        "/etc/machine-id",
    ]
    if shutil.which("rsync"):
        cmd = [
            "rsync",
            "-aHAX",
            "--numeric-ids",
            "--info=progress2",
            "--delete",
        ]
        for pattern in excludes:
            cmd.append(f"--exclude={pattern}")
        cmd.extend(["/", f"{MOUNTPOINT}/"])
        runner.run(cmd)
    else:
        tar_excludes = [f"--exclude=.{pattern}" for pattern in excludes]
        runner.run([
            "bash",
            "-c",
            (
                "set -euo pipefail; "
                "cd /; "
                "tar --xattrs --acls --one-file-system "
                + " ".join(tar_excludes)
                + f" -cpf - . | tar --xattrs --acls -xpf - -C {MOUNTPOINT}"
            ),
        ])

    for directory in ("dev", "proc", "sys", "run", "tmp", "mnt", "media"):
        Path(f"{MOUNTPOINT}/{directory}").mkdir(parents=True, exist_ok=True)
    runner.run(["chmod", "1777", f"{MOUNTPOINT}/tmp"], check=False)


def install_live_kernel(runner: CommandRunner) -> None:
    """Ensure the installed EFI partition has the kernel and initramfs."""
    boot_dir = Path(f"{MOUNTPOINT}/boot")
    boot_dir.mkdir(parents=True, exist_ok=True)

    kernel_sources = [
        Path("/run/archiso/bootmnt/arch/boot/x86_64/vmlinuz-linux-cachyos"),
        Path("/run/archiso/bootmnt/arch/boot/x86_64/vmlinuz-linux"),
        Path("/boot/vmlinuz-linux-cachyos"),
        Path("/boot/vmlinuz-linux"),
    ]
    kernel_sources.extend(Path("/usr/lib/modules").glob("*/vmlinuz"))

    initramfs_sources = [
        Path("/run/archiso/bootmnt/arch/boot/x86_64/initramfs-linux-cachyos.img"),
        Path("/run/archiso/bootmnt/arch/boot/x86_64/initramfs-linux.img"),
        Path("/boot/initramfs-linux-cachyos.img"),
        Path("/boot/initramfs-linux.img"),
    ]

    kernel_copied = False
    for src in kernel_sources:
        if src.exists():
            shutil.copy2(src, boot_dir / "vmlinuz-linux-cachyos")
            kernel_copied = True
            break

    initramfs_dest = boot_dir / "initramfs-linux-cachyos.img"
    if not initramfs_dest.exists():
        for src in initramfs_sources:
            if src.exists():
                shutil.copy2(src, initramfs_dest)
                break

    if not kernel_copied:
        raise InstallError("Could not find the live kernel to install to /boot.")


def generate_fstab(runner: CommandRunner) -> None:
    """Generate /etc/fstab using filesystem labels."""
    runner.run(
        ["bash", "-c", f"genfstab -L {MOUNTPOINT} > {MOUNTPOINT}/etc/fstab"]
    )


def configure_system(runner: CommandRunner) -> None:
    """Post-install system configuration inside chroot."""
    mnt = MOUNTPOINT

    # Machine identity
    _write_file(f"{mnt}/etc/machine-id", "")
    runner.run_chroot(["systemd-machine-id-setup"])

    # Timezone
    runner.run_chroot(
        ["ln", "-sf", "/usr/share/zoneinfo/UTC", "/etc/localtime"]
    )
    runner.run_chroot(["hwclock", "--systohc"])

    # Locale
    _write_file(f"{mnt}/etc/locale.gen", "en_US.UTF-8 UTF-8\n")
    runner.run_chroot(["locale-gen"])
    _write_file(f"{mnt}/etc/locale.conf", "LANG=en_US.UTF-8\nLC_COLLATE=C\n")

    # Hostname
    _write_file(f"{mnt}/etc/hostname", "amicachy\n")

    # Console
    _write_file(f"{mnt}/etc/vconsole.conf", "KEYMAP=us\nFONT=ter-v16n\n")

    # Pacman config with CachyOS repos
    src_pacman = f"{INSTALLER_DATA_DIR}/pacman.conf"
    if Path(src_pacman).exists():
        shutil.copy2(src_pacman, f"{mnt}/etc/pacman.conf")

    # CachyOS mirrorlists
    for ml in ("cachyos-mirrorlist", "cachyos-v3-mirrorlist"):
        src = f"{INSTALLER_DATA_DIR}/{ml}"
        if Path(src).exists():
            shutil.copy2(src, f"{mnt}/etc/pacman.d/{ml}")

    # Create or normalize amiga user
    if runner.run_chroot(["id", "-u", "amiga"], check=False).returncode == 0:
        runner.run_chroot([
            "usermod",
            "-aG", "wheel,audio,video,input",
            "-s", "/bin/bash",
            "-c", "Amiga User",
            "amiga",
        ])
    else:
        runner.run_chroot([
            "useradd", "-m",
            "-G", "wheel,audio,video,input",
            "-s", "/bin/bash",
            "-c", "Amiga User",
            "amiga",
        ])
    runner.run_chroot(["passwd", "-d", "amiga"])

    # Auto-login on TTY1. We keep the login path because Cage/logind works
    # reliably from it, but suppress issue/login noise and clear immediately.
    autologin_dir = f"{mnt}/etc/systemd/system/getty@tty1.service.d"
    Path(autologin_dir).mkdir(parents=True, exist_ok=True)
    _write_file(
        f"{autologin_dir}/autologin.conf",
        "[Service]\nExecStart=\n"
        "ExecStart=-/sbin/agetty --autologin amiga --noissue %I $TERM\n"
        "Type=idle\n",
    )

    # RT priority limits
    Path(f"{mnt}/etc/security/limits.d").mkdir(parents=True, exist_ok=True)
    _write_file(
        f"{mnt}/etc/security/limits.d/90-amiga-rtprio.conf",
        "amiga  -  rtprio    99\n"
        "amiga  -  memlock   unlimited\n"
        "amiga  -  nice      -20\n",
    )

    # PAM config for cage
    Path(f"{mnt}/etc/pam.d").mkdir(parents=True, exist_ok=True)
    pam_src = f"{INSTALLER_DATA_DIR}/pam.d/cage"
    if Path(pam_src).exists():
        shutil.copy2(pam_src, f"{mnt}/etc/pam.d/cage")
    else:
        _write_file(
            f"{mnt}/etc/pam.d/cage",
            "#%PAM-1.0\n"
            "auth       required   pam_unix.so\n"
            "auth       optional   pam_permit.so\n"
            "account    required   pam_unix.so\n"
            "account    optional   pam_permit.so\n"
            "session    required   pam_unix.so\n"
            "session    required   pam_loginuid.so\n"
            "session    optional   pam_systemd.so\n",
        )

    # Scripts: launcher, Amiberry session helper, Dev tools
    for script in ("amilaunch.sh", "amicachy-amiberry-session", "start_dev_env.sh", "amicachy-copy-roms"):
        src = f"{INSTALLER_DATA_DIR}/{script}"
        dest = f"{mnt}/usr/bin/{script}"
        if Path(src).exists():
            shutil.copy2(src, dest)
        runner.run_chroot(["chmod", "+x", f"/usr/bin/{script}"])

    labwc_emulator_src = f"{INSTALLER_DATA_DIR}/labwc-emulator"
    if Path(labwc_emulator_src).is_dir():
        shutil.copytree(
            labwc_emulator_src,
            f"{mnt}/etc/amicachy/labwc-emulator",
            dirs_exist_ok=True,
        )

    # UAE configs
    uae_dest = f"{mnt}/usr/share/amicachy/uae"
    Path(uae_dest).mkdir(parents=True, exist_ok=True)
    for uae in ("a1200.uae", "os41.uae"):
        src = f"{INSTALLER_DATA_DIR}/uae/{uae}"
        if Path(src).exists():
            shutil.copy2(src, f"{uae_dest}/{uae}")

    # .bash_profile
    _write_file(
        f"{mnt}/home/amiga/.bash_profile",
        '# Auto-launch on TTY1\n'
        'if [[ "$(tty)" == "/dev/tty1" ]]; then\n'
        "    printf '\\e[?25l'\n"
        "    printf '\\033[H\\033[2J\\033[3J'\n"
        '    exec /usr/bin/amilaunch.sh\n'
        'fi\n',
    )
    _write_file(f"{mnt}/home/amiga/.hushlogin", "")

    # Labwc config
    labwc_dest = f"{mnt}/home/amiga/.config/labwc"
    Path(labwc_dest).mkdir(parents=True, exist_ok=True)
    for fname in ("autostart", "environment", "rc.xml"):
        src = f"{INSTALLER_DATA_DIR}/labwc/{fname}"
        if Path(src).exists():
            shutil.copy2(src, f"{labwc_dest}/{fname}")

    # Amiga directory structure
    for d in AMIGA_DIRS:
        Path(f"{mnt}/home/amiga/{d}").mkdir(parents=True, exist_ok=True)

    # Fix ownership
    runner.run_chroot(["chown", "-R", "amiga:amiga", "/home/amiga"])

    # Enable NetworkManager
    runner.run_chroot(["systemctl", "enable", "NetworkManager"])

    # Plymouth boot splash
    plymouth_theme = f"{mnt}/usr/share/plymouth/themes/amicachy"
    plymouth_src = "/usr/share/plymouth/themes/amicachy"
    if Path(plymouth_src).is_dir():
        shutil.copytree(plymouth_src, plymouth_theme, dirs_exist_ok=True)
    _write_file(
        f"{mnt}/etc/plymouth/plymouthd.conf",
        "[Daemon]\nTheme=amicachy\nShowDelay=0\nDeviceTimeout=5\n",
    )
    _write_file(
        f"{mnt}/etc/systemd/system/plymouth-quit.service.d/retain-splash.conf",
        "[Service]\nExecStart=\nExecStart=/usr/bin/plymouth quit\n",
    )
    # mkinitcpio with plymouth hook
    _write_file(
        f"{mnt}/etc/mkinitcpio.conf",
        "MODULES=()\nBINARIES=()\nFILES=()\n"
        "HOOKS=(base udev plymouth autodetect modconf kms block filesystems keyboard)\n",
    )
    # Plymouth systemd services
    for wants_dir, service in [
        ("sysinit.target.wants", "plymouth-start.service"),
        ("multi-user.target.wants", "plymouth-quit.service"),
    ]:
        link_dir = f"{mnt}/etc/systemd/system/{wants_dir}"
        Path(link_dir).mkdir(parents=True, exist_ok=True)
        link_path = Path(f"{link_dir}/{service}")
        if not link_path.exists():
            link_path.symlink_to(f"/usr/lib/systemd/system/{service}")
    wait_link = Path(f"{mnt}/etc/systemd/system/multi-user.target.wants/plymouth-quit-wait.service")
    if wait_link.exists() or wait_link.is_symlink():
        wait_link.unlink()

    # Regenerate initramfs (with plymouth hook now active)
    runner.run_chroot(["mkinitcpio", "-P"])


def _iter_rom_files(source: Path):
    for root, dirs, files in os.walk(source):
        dirs[:] = [
            directory for directory in dirs
            if directory.lower() not in BOOT_MEDIA_SKIP_DIRS
            and not directory.startswith(".")
        ]
        for name in files:
            path = Path(root) / name
            if path.suffix.lower() in ROM_SUFFIXES:
                yield path


def copy_rom_payload(runner: CommandRunner) -> None:
    """Copy user-provided ROM/Kickstart files from live media to the install."""
    destination = Path(f"{MOUNTPOINT}/home/amiga/kickstarts")
    destination.mkdir(parents=True, exist_ok=True)

    sources = [
        Path("/run/archiso/bootmnt"),
        Path("/run/media/amiga"),
    ]

    copied = 0
    seen: set[Path] = set()

    for source in sources:
        if not source.exists():
            continue
        for rom in _iter_rom_files(source):
            try:
                resolved = rom.resolve()
            except OSError:
                resolved = rom
            if resolved in seen:
                continue
            seen.add(resolved)

            dest = destination / rom.name
            shutil.copy2(rom, dest)
            copied += 1
            runner.log(f"Copied ROM payload: {rom} -> {dest}")

    if copied:
        runner.run_chroot(["chown", "-R", "amiga:amiga", "/home/amiga/kickstarts"], check=False)
    else:
        runner.log("No ROM payload files found on live media.")


def install_bootloader(
    runner: CommandRunner,
    selected_profiles: list[str],
    default_profile: str,
) -> None:
    """Install systemd-boot and create boot entries for selected profiles."""
    mnt = MOUNTPOINT

    runner.run_chroot(["bootctl", "install"])
    install_mac_fallback_bootloader(runner)

    # loader.conf
    default_entry = BOOT_ENTRIES[default_profile]["filename"]
    _write_file(
        f"{mnt}/boot/loader/loader.conf",
        LOADER_CONF_TEMPLATE.format(default_entry=default_entry),
    )

    # Boot entries: user-selected profiles plus the always-installed ones
    # (asset_manager). Order is preserved so the menu lists the user's
    # picks first and 'Asset Manager' last.
    entries_dir = f"{mnt}/boot/loader/entries"
    Path(entries_dir).mkdir(parents=True, exist_ok=True)

    from .resources import ALWAYS_INSTALL_ENTRIES
    seen: set[str] = set()
    to_write: list[str] = []
    for pid in list(selected_profiles) + list(ALWAYS_INSTALL_ENTRIES):
        if pid in seen or pid not in BOOT_ENTRIES:
            continue
        seen.add(pid)
        to_write.append(pid)

    for profile_id in to_write:
        entry = BOOT_ENTRIES[profile_id]
        content = (
            f"title   {entry['title']}\n"
            f"linux   /vmlinuz-linux-cachyos\n"
            f"initrd  /initramfs-linux-cachyos.img\n"
            f"options {entry['options']}\n"
        )
        _write_file(f"{entries_dir}/{entry['filename']}", content)


def install_addon(runner: CommandRunner, asset_id: str) -> None:
    """Run amicachy-fetch-asset inside the chroot, as user 'amiga'.

    Using runuser keeps HOME, downloads, extraction and the generated .uae
    inside /home/amiga (the live target user's home), exactly as if the
    user had run the Asset Manager themselves after first boot.

    --accept skips the interactive license prompt; the installer's own
    Add-ons page already obtained explicit consent before reaching here.
    """
    runner.run_chroot([
        "runuser", "-u", "amiga", "--",
        "amicachy-fetch-asset", "--accept", "install", asset_id,
    ])


def install_mac_fallback_bootloader(runner: CommandRunner) -> None:
    """Install the removable/fallback EFI path used by Apple's boot picker."""
    fallback_dir = Path(f"{MOUNTPOINT}/boot/EFI/BOOT")
    fallback_dir.mkdir(parents=True, exist_ok=True)

    candidates = [
        Path(f"{MOUNTPOINT}/boot/EFI/systemd/systemd-bootx64.efi"),
        Path(f"{MOUNTPOINT}/usr/lib/systemd/boot/efi/systemd-bootx64.efi"),
    ]

    for candidate in candidates:
        if candidate.exists():
            shutil.copy2(candidate, fallback_dir / "BOOTX64.EFI")
            return

    raise InstallError(
        "Could not find systemd-bootx64.efi to install the Mac EFI fallback."
    )


def final_cleanup(runner: CommandRunner) -> None:
    """Sync and unmount all filesystems."""
    runner.run(["sync"])
    # Unmount with retries
    for attempt in range(3):
        result = runner.run(["umount", "-R", MOUNTPOINT], check=False)
        if result.returncode == 0:
            return
        time.sleep(2)
    # Final attempt with force
    runner.run(["umount", "-lR", MOUNTPOINT], check=False)


def emergency_cleanup(runner: CommandRunner) -> None:
    """Best-effort unmount after a failed installation."""
    # We don't have the partitions dict here easily, so we just try all
    for path in [
        f"{MOUNTPOINT}/home/amiga/Amiga",
        f"{MOUNTPOINT}/boot",
        MOUNTPOINT,
    ]:
        # Ignore errors if not mounted
        runner.run(["umount", "-l", path], check=False)
