"""QThread workers for long-running operations."""

import json
import subprocess
from dataclasses import dataclass, field

from PySide6.QtCore import QThread, Signal

from .backend import (
    CommandRunner,
    InstallError,
    NetworkError,
    configure_system,
    emergency_cleanup,
    final_cleanup,
    generate_fstab,
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

    def run(self):
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
            )
            data = json.loads(result.stdout)

            # Find the device backing the live USB (mounted at /)
            live_device = ""
            try:
                findmnt = subprocess.run(
                    ["findmnt", "-n", "-o", "SOURCE", "/"],
                    capture_output=True,
                    text=True,
                )
                live_source = findmnt.stdout.strip()
                # Strip partition suffix to get parent device
                # /dev/sda1 -> sda, /dev/nvme0n1p1 -> nvme0n1
                import re
                match = re.match(r"/dev/(\w+?)(?:p?\d+)?$", live_source)
                if match:
                    live_device = match.group(1)
            except (subprocess.CalledProcessError, ValueError):
                pass

            for dev in data.get("blockdevices", []):
                if dev.get("type") != "disk":
                    continue
                if dev.get("ro", False):
                    continue
                if dev.get("rm", False):
                    continue
                name = dev.get("name", "")
                if name == live_device:
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

        except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError):
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

        # Step 7: Install bootloader
        self.step_changed.emit("Installing boot manager...", 87)
        install_bootloader(
            runner,
            self.state.selected_profiles,
            self.state.default_profile,
        )
        self.step_changed.emit("Boot manager installed.", 92)

        # Step 8: Cleanup
        self.step_changed.emit("Finalizing...", 95)
        final_cleanup(runner)
        self.step_changed.emit("Installation complete!", 100)
