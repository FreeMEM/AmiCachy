"""Installation backend — shell command sequences for system deployment.

All disk operations, pacstrap, chroot configuration, and bootloader
setup are encapsulated here. Every command runs through CommandRunner
for consistent logging and error handling.
"""

import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Callable

from .resources import (
    AMIGA_DIRS,
    BOOT_ENTRIES,
    CACHYOS_GPG_KEY,
    INSTALLER_DATA_DIR,
    INSTALL_LOG_PATH,
    LOADER_CONF_TEMPLATE,
    MOUNTPOINT,
)


class InstallError(Exception):
    """Base exception for installation failures."""

    def __init__(self, message: str, step: str = "", recoverable: bool = False):
        super().__init__(message)
        self.step = step
        self.recoverable = recoverable


class NetworkError(InstallError):
    """Network-related failures (pacstrap download)."""

    def __init__(self, message: str):
        super().__init__(message, step="pacstrap", recoverable=True)


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


# ---------------------------------------------------------------------------
# Installation steps
# ---------------------------------------------------------------------------


def partition_disk(runner: CommandRunner, device: str) -> dict[str, str]:
    """Create GPT partition table with EFI, Root, and Data partitions."""
    runner.run(["wipefs", "--all", "--force", device])
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
    runner.run(["mkfs.ext4", "-F", "-L", "AMICACHY", partitions["root"]])
    runner.run(["mkfs.ext4", "-F", "-L", "AMIGADATA", partitions["data"]])

    return partitions


def mount_filesystems(runner: CommandRunner, partitions: dict[str, str]) -> None:
    """Mount root, EFI, and data partitions under MOUNTPOINT."""
    runner.run(["mount", partitions["root"], MOUNTPOINT])
    runner.run(["mkdir", "-p", f"{MOUNTPOINT}/boot"])
    runner.run(["mount", partitions["efi"], f"{MOUNTPOINT}/boot"])
    runner.run(["mkdir", "-p", f"{MOUNTPOINT}/home/amiga/Amiga"])
    runner.run(["mount", partitions["data"], f"{MOUNTPOINT}/home/amiga/Amiga"])


def setup_pacman(runner: CommandRunner) -> None:
    """Import CachyOS GPG key for package verification."""
    runner.run(
        ["pacman-key", "--recv-keys", CACHYOS_GPG_KEY], check=False
    )
    runner.run(
        ["pacman-key", "--lsign-key", CACHYOS_GPG_KEY], check=False
    )


def read_package_list(packages_file: str) -> list[str]:
    """Read package names from packages.x86_64, skipping comments."""
    packages: list[str] = []
    with open(packages_file) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                packages.append(line)
    return packages


def run_pacstrap(runner: CommandRunner, packages: list[str]) -> None:
    """Install packages to target using pacstrap with CachyOS repos."""
    pacman_conf = f"{INSTALLER_DATA_DIR}/pacman.conf"
    # Fallback to system pacman.conf if installer data not present
    if not Path(pacman_conf).exists():
        pacman_conf = "/etc/pacman.conf"
    try:
        runner.run(["pacstrap", "-C", pacman_conf, MOUNTPOINT] + packages)
    except InstallError as e:
        error_msg = str(e).lower()
        if "could not resolve" in error_msg or "connection" in error_msg:
            raise NetworkError(f"Network error during package installation: {e}")
        raise


def generate_fstab(runner: CommandRunner) -> None:
    """Generate /etc/fstab using filesystem labels."""
    runner.run(
        ["bash", "-c", f"genfstab -L {MOUNTPOINT} >> {MOUNTPOINT}/etc/fstab"]
    )


def configure_system(runner: CommandRunner) -> None:
    """Post-install system configuration inside chroot."""
    mnt = MOUNTPOINT

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

    # Create amiga user
    runner.run_chroot([
        "useradd", "-m",
        "-G", "wheel,audio,video,input",
        "-s", "/bin/bash",
        "-c", "Amiga User",
        "amiga",
    ])
    runner.run_chroot(["passwd", "-d", "amiga"])

    # Auto-login on TTY1
    autologin_dir = f"{mnt}/etc/systemd/system/getty@tty1.service.d"
    Path(autologin_dir).mkdir(parents=True, exist_ok=True)
    _write_file(
        f"{autologin_dir}/autologin.conf",
        "[Service]\nExecStart=\n"
        "ExecStart=-/sbin/agetty --autologin amiga --noclear %I $TERM\n"
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

    # Scripts: amilaunch.sh, start_dev_env.sh
    for script in ("amilaunch.sh", "start_dev_env.sh"):
        src = f"{INSTALLER_DATA_DIR}/{script}"
        dest = f"{mnt}/usr/bin/{script}"
        if Path(src).exists():
            shutil.copy2(src, dest)
        runner.run_chroot(["chmod", "+x", f"/usr/bin/{script}"])

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
        '    exec /usr/bin/amilaunch.sh\n'
        'fi\n',
    )

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

    # Regenerate initramfs
    runner.run_chroot(["mkinitcpio", "-P"])


def install_bootloader(
    runner: CommandRunner,
    selected_profiles: list[str],
    default_profile: str,
) -> None:
    """Install systemd-boot and create boot entries for selected profiles."""
    mnt = MOUNTPOINT

    runner.run_chroot(["bootctl", "install"])

    # loader.conf
    default_entry = BOOT_ENTRIES[default_profile]["filename"]
    _write_file(
        f"{mnt}/boot/loader/loader.conf",
        LOADER_CONF_TEMPLATE.format(default_entry=default_entry),
    )

    # Boot entries (only for selected profiles)
    entries_dir = f"{mnt}/boot/loader/entries"
    Path(entries_dir).mkdir(parents=True, exist_ok=True)

    for profile_id in selected_profiles:
        entry = BOOT_ENTRIES[profile_id]
        content = (
            f"title   {entry['title']}\n"
            f"linux   /vmlinuz-linux-cachyos\n"
            f"initrd  /initramfs-linux-cachyos.img\n"
            f"options {entry['options']}\n"
        )
        _write_file(f"{entries_dir}/{entry['filename']}", content)


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
    for path in [
        f"{MOUNTPOINT}/home/amiga/Amiga",
        f"{MOUNTPOINT}/boot",
        MOUNTPOINT,
    ]:
        runner.run(["umount", path], check=False)
