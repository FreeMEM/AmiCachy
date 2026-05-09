"""QThread workers for long-running operations."""

import json
import re
import subprocess
from dataclasses import dataclass, field

from PySide6.QtCore import QThread, Signal

from .backend import (
    CommandRunner,
    InstallError,
    NetworkError,
    configure_system,
    copy_rom_payload,
    emergency_cleanup,
    final_cleanup,
    generate_fstab,
    install_addon,
    install_bootloader,
    mount_filesystems,
    partition_disk,
    read_package_list,
    run_pacstrap,
    setup_pacman,
)
from .hardware import (
    detect_arch_level,
    detect_virtualization,
    read_cpuinfo,
    recommend_profiles,
    run_benchmark,
)
from .resources import INSTALLER_DATA_DIR, MOUNTPOINT


@dataclass
class InstallerState:
    """Shared state passed between wizard pages."""

    # Hardware audit
    audit_result: dict = field(default_factory=dict)

    # Disk selection
    target_device: str = ""
    target_device_model: str = ""
    target_device_size: int = 0

    # Profile selection
    selected_profiles: list[str] = field(default_factory=list)
    default_profile: str = "classic_68k"

    # Optional asset bundles to fetch after the base install
    selected_addons: list[str] = field(default_factory=list)

    # Computed during installation
    partitions: dict[str, str] = field(default_factory=dict)


class HardwareAuditWorker(QThread):
    """Runs CPU detection, virtualization check, and benchmark."""

    progress = Signal(str)
    finished = Signal(dict)

    def run(self):
        self.progress.emit("Reading CPU information...")
        cpuinfo = read_cpuinfo()
        arch_level = detect_arch_level(cpuinfo["flags"])

        self.progress.emit("Checking virtualization support...")
        virt = detect_virtualization(cpuinfo["flags"])

        self.progress.emit("Running performance benchmark...")
        bench = run_benchmark(duration_s=3.0)

        profiles = recommend_profiles(arch_level, virt, bench)

        result = {
            "cpu": {
                "model": cpuinfo["model"],
                "cores": cpuinfo["cores"],
                "threads": cpuinfo["threads"],
                "arch_level": arch_level,
            },
            "virtualization": virt,
            "benchmark": bench,
            "profiles": profiles,
        }
        self.finished.emit(result)


class DiskScanWorker(QThread):
    """Scans available block devices for installation targets."""

    finished = Signal(list)

    @staticmethod
    def _find_live_devices() -> set[str]:
        """Identify devices backing the live ISO so they are not install targets.

        Checks both the rootfs source (/) and /run/archiso/bootmnt; on archiso
        the latter is the actual USB block device while / is an overlay/loop.
        Symlinks are resolved and the parent disk name is added too so a USB
        with multiple partitions is fully excluded.
        """
        live_devices: set[str] = set()

        for mountpoint in ("/run/archiso/bootmnt", "/"):
            try:
                findmnt = subprocess.run(
                    ["findmnt", "-n", "-o", "SOURCE", mountpoint],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                live_source = findmnt.stdout.strip()
                if not live_source:
                    continue

                resolved = subprocess.run(
                    ["readlink", "-f", live_source],
                    capture_output=True,
                    text=True,
                    timeout=5,
                ).stdout.strip() or live_source

                if not resolved.startswith("/dev/"):
                    continue

                name = resolved.rsplit("/", 1)[-1]
                live_devices.add(name)

                # Add parent disk too (e.g. /dev/sda1 -> sda)
                try:
                    pkname = subprocess.run(
                        ["lsblk", "-no", "PKNAME", resolved],
                        capture_output=True,
                        text=True,
                        timeout=5,
                    ).stdout.strip()
                    if pkname:
                        live_devices.add(pkname)
                except (subprocess.SubprocessError, FileNotFoundError):
                    m = re.match(r"/dev/(nvme\d+n\d+|mmcblk\d+|[a-z]+)", resolved)
                    if m:
                        live_devices.add(m.group(1))
            except (subprocess.SubprocessError, FileNotFoundError):
                continue

        return live_devices

    def run(self):
        # Trigger kernel partition re-read before scanning — essential on
        # MacBooks where Apple NVMe SSDs may not appear in lsblk until the
        # kernel has probed them.
        try:
            subprocess.run(["partprobe"], capture_output=True, timeout=10)
        except (subprocess.SubprocessError, FileNotFoundError):
            pass

        disks: list[dict] = []
        try:
            result = subprocess.run(
                [
                    "lsblk", "--json", "--bytes",
                    "--output", "NAME,SIZE,MODEL,TYPE,TRAN,RO,RM",
                ],
                capture_output=True,
                text=True,
                check=True,
                timeout=10,
            )
            data = json.loads(result.stdout)

            live_devices = self._find_live_devices()

            for dev in data.get("blockdevices", []):
                if dev.get("type") != "disk":
                    continue
                if dev.get("ro", False):
                    continue
                if dev.get("rm", False):
                    continue
                name = dev.get("name", "")
                if name in live_devices:
                    continue
                size = int(dev.get("size", 0))
                if size < 20 * 1024 * 1024 * 1024:  # 20 GiB minimum
                    continue

                model = dev.get("model", "").strip() or "Unknown drive"
                transport = dev.get("tran", "") or ""
                size_gb = size / (1024 ** 3)

                disks.append({
                    "name": name,
                    "device": f"/dev/{name}",
                    "model": model,
                    "transport": transport.upper(),
                    "size": size,
                    "size_display": f"{size_gb:.1f} GB",
                })

        except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
                json.JSONDecodeError, KeyError):
            pass

        self.finished.emit(disks)


class InstallWorker(QThread):
    """Runs the entire installation sequence."""

    step_changed = Signal(str, int)  # (description, progress_percent)
    log_line = Signal(str)
    finished = Signal(bool, str)  # (success, error_message)

    def __init__(self, state: InstallerState):
        super().__init__()
        self.state = state

    def run(self):
        runner = CommandRunner(log_callback=self.log_line.emit)
        try:
            self._do_install(runner)
            self.finished.emit(True, "")
        except NetworkError as e:
            self.log_line.emit(f"NETWORK ERROR: {e}")
            emergency_cleanup(runner)
            self.finished.emit(False, str(e))
        except InstallError as e:
            self.log_line.emit(f"ERROR: {e}")
            emergency_cleanup(runner)
            self.finished.emit(False, str(e))
        except Exception as e:
            self.log_line.emit(f"UNEXPECTED ERROR: {e}")
            emergency_cleanup(runner)
            self.finished.emit(False, f"Unexpected error: {e}")
        finally:
            runner.close()

    def _do_install(self, runner: CommandRunner) -> None:
        device = self.state.target_device

        # Step 1: Partition disk
        self.step_changed.emit("Preparing disk...", 2)
        self.state.partitions = partition_disk(runner, device)
        self.step_changed.emit("Disk partitioned.", 10)

        # Step 2: Mount filesystems
        self.step_changed.emit("Mounting filesystems...", 12)
        mount_filesystems(runner, self.state.partitions)
        self.step_changed.emit("Filesystems mounted.", 15)

        # Step 3: Setup pacman keys
        self.step_changed.emit("Configuring package manager...", 17)
        setup_pacman(runner)
        self.step_changed.emit("Package manager ready.", 20)

        # Step 4: Pacstrap (longest step)
        self.step_changed.emit("Installing packages (this may take a while)...", 22)
        packages_file = f"{INSTALLER_DATA_DIR}/packages.x86_64"
        packages = read_package_list(packages_file)
        run_pacstrap(runner, packages)
        self.step_changed.emit("Packages installed.", 70)

        # Step 5: Generate fstab
        self.step_changed.emit("Generating filesystem table...", 71)
        generate_fstab(runner)
        self.step_changed.emit("Filesystem table generated.", 72)

        # Step 6: Configure system
        self.step_changed.emit("Configuring system...", 74)
        configure_system(runner)
        self.step_changed.emit("System configured.", 85)

        # Step 6b: Copy any user-supplied ROMs/Kickstarts found on the live
        # media (USB root, /run/media/amiga). Best-effort: missing ROMs are
        # not an installation failure — the Asset Manager can fetch them
        # on first boot.
        self.step_changed.emit("Copying ROM files (if present)...", 86)
        try:
            copy_rom_payload(runner)
        except Exception as e:
            self.log_line.emit(f"WARNING: ROM payload copy failed: {e}")

        # Step 7: Install bootloader
        self.step_changed.emit("Installing boot manager...", 87)
        install_bootloader(
            runner,
            self.state.selected_profiles,
            self.state.default_profile,
        )
        self.step_changed.emit("Boot manager installed.", 90)

        # Step 8: Optional add-ons (asset bundles selected on the Add-ons page)
        if self.state.selected_addons:
            n = len(self.state.selected_addons)
            for i, asset_id in enumerate(self.state.selected_addons, 1):
                self.step_changed.emit(
                    f"Downloading add-on {i}/{n}: {asset_id}…",
                    90 + int(4 * i / n),
                )
                install_addon(runner, asset_id)
            self.step_changed.emit("Add-ons installed.", 94)

        # Step 9: Cleanup
        self.step_changed.emit("Finalizing...", 95)
        final_cleanup(runner)
        self.step_changed.emit("Installation complete!", 100)
