"""QThread workers for long-running operations."""

import json
import re
import subprocess
from dataclasses import dataclass, field

from PySide6.QtCore import QThread, Signal

from .backend import (
    CommandRunner,
    InstallError,
    configure_system,
    copy_live_system,
    copy_rom_payload,
    emergency_cleanup,
    final_cleanup,
    generate_fstab,
    install_addon,
    install_live_kernel,
    install_bootloader,
    mount_filesystems,
    partition_disk,
    clear_filesystem_signatures,
    format_ext4,
    recreate_partition,
    release_install_target,
)
from .hardware import (
    detect_arch_level,
    detect_virtualization,
    read_cpuinfo,
    recommend_profiles,
    run_benchmark,
)
from .resources import MIN_DISK_SIZE


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
    is_partition: bool = False


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
    def _base_device_name(path: str) -> str:
        """Return the parent disk name for a /dev path."""
        try:
            result = subprocess.run(
                ["lsblk", "-no", "PKNAME", path],
                capture_output=True,
                text=True,
                timeout=5,
            )
            parent = result.stdout.strip()
            if parent:
                return parent
        except (subprocess.SubprocessError, FileNotFoundError):
            pass

        m = re.match(r"/dev/(nvme\d+n\d+|mmcblk\d+|[a-z]+)", path)
        return m.group(1) if m else ""

    @staticmethod
    def _find_live_devices() -> set[str]:
        """Identify devices backing the live ISO so they are not install targets."""
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
                base = DiskScanWorker._base_device_name(resolved)
                if base:
                    live_devices.add(base)
            except (subprocess.SubprocessError, FileNotFoundError):
                continue

        return live_devices

    @staticmethod
    def _flatten_lsblk(devices: list[dict], parent: dict | None = None) -> list[tuple[dict, dict | None]]:
        flattened: list[tuple[dict, dict | None]] = []
        for dev in devices:
            flattened.append((dev, parent))
            flattened.extend(DiskScanWorker._flatten_lsblk(dev.get("children", []), dev))
        return flattened

    @staticmethod
    def _partition_parent(partition: str) -> str:
        """Determine the parent disk for a selected partition."""
        try:
            result = subprocess.run(
                ["lsblk", "-no", "PKNAME", partition],
                capture_output=True,
                text=True,
                check=True,
                timeout=5,
            )
            parent = result.stdout.strip()
            if parent:
                return f"/dev/{parent}"
        except (subprocess.SubprocessError, FileNotFoundError):
            pass

        m = re.match(r"(/dev/(?:nvme\d+n\d+|mmcblk\d+|[a-z]+))(?:p?\d+)$", partition)
        if m:
            return m.group(1)
        return ""

    def run(self):
        # Trigger kernel partition re-read before scanning —
        # essential on MacBooks where Apple NVMe SSDs may not appear
        # in lsblk until the kernel has probed them.
        subprocess.run(["partprobe"], capture_output=True, timeout=10)

        disks: list[dict] = []
        try:
            result = subprocess.run(
                [
                    "lsblk", "--json", "--bytes",
                    "--output", "NAME,PATH,PKNAME,SIZE,MODEL,TYPE,TRAN,RO,RM,LABEL,FSTYPE,PARTLABEL,MOUNTPOINTS",
                ],
                capture_output=True,
                text=True,
                check=True,
                timeout=10,
            )
            data = json.loads(result.stdout)
            live_devices = self._find_live_devices()

            for dev, parent in self._flatten_lsblk(data.get("blockdevices", [])):
                if dev.get("type") not in ("disk", "part"):
                    continue
                if dev.get("ro", False):
                    continue

                name = dev.get("name", "")
                parent_name = dev.get("pkname") or (parent or {}).get("name", "")
                if name in live_devices or parent_name in live_devices:
                    continue

                size = int(dev.get("size", 0))
                min_size = 8 * 1024 * 1024 * 1024 if dev.get("type") == "part" else MIN_DISK_SIZE
                if size < min_size:
                    continue

                model = (dev.get("model") or "").strip() or "Unknown drive"
                label = (dev.get("label") or "").strip()
                fstype = (dev.get("fstype") or "").strip()
                partlabel = (dev.get("partlabel") or "").strip()

                if dev.get("type") == "part":
                    display_name = f"Partition: {name}"
                    if label:
                        display_name += f" ({label})"
                    elif partlabel:
                        display_name += f" ({partlabel})"
                    elif fstype:
                        display_name += f" [{fstype}]"
                else:
                    display_name = model

                size_gb = size / (1024 ** 3)

                # Determine a user-friendly transport label
                transport = (dev.get("tran") or (parent or {}).get("tran") or "").strip()
                if not transport:
                    if dev.get("type") == "part":
                        transport = "PARTITION"
                    else:
                        # Try reading from sysfs (e.g. Apple NVMe reports here)
                        try:
                            with open(f"/sys/block/{name}/device/transport") as f:
                                transport = f.read().strip()
                        except (FileNotFoundError, PermissionError):
                            # Fallback: check if it's NVMe by name pattern
                            if name.startswith("nvme"):
                                transport = "nvme"
                            else:
                                transport = "disk"

                disks.append({
                    "name": name,
                    "device": dev.get("path") or f"/dev/{name}",
                    "model": display_name,
                    "is_partition": dev.get("type") == "part",
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

    def _prepare_selected_partition(self, runner: CommandRunner, partition: str) -> dict[str, str]:
        """Use an existing partition for root, and try to find an EFI sibling."""
        self.log_line.emit(f"Using partition {partition} as root.")

        # Determine the parent disk
        disk = DiskScanWorker._partition_parent(partition)
        if not disk:
             raise InstallError(f"Could not determine parent disk for {partition}")

        # Look for an EFI partition on the same disk
        efi_part = ""
        try:
            result = subprocess.run(
                ["lsblk", disk, "--json", "-o", "NAME,FSTYPE,PARTLABEL"],
                capture_output=True, text=True, check=True
            )
            data = json.loads(result.stdout)
            # Find a FAT32 partition or one labeled EFI/ESP
            for dev in data.get("blockdevices", []):
                for child in dev.get("children", []):
                    # child name is like 'sda1', need to prepend /dev/
                    child_path = f"/dev/{child['name']}"
                    fstype = (child.get("fstype") or "").lower()
                    label = (child.get("partlabel") or "").lower()
                    if "fat" in fstype or "efi" in label or "esp" in label:
                        efi_part = child_path
                        break
                if efi_part: break
        except Exception:
            pass

        if not efi_part:
            self.log_line.emit("WARNING: No EFI partition found on disk. Installation might fail to boot.")
            # We could try to use the root partition if it's FAT32, but it won't be.
            # For now, let's just use the first partition as a guess or error.
            # But wait, if it's Legacy BIOS, we might not need one?
            # Systemd-boot requires EFI.
            raise InstallError("No EFI partition found. AmiCachy requires a GPT disk with an EFI (FAT32) partition.")

        self.log_line.emit(f"Found EFI partition: {efi_part}")

        # Wipe ONLY the root partition, not the whole disk
        release_install_target(runner, partition)
        clear_filesystem_signatures(runner, partition)
        try:
            format_ext4(runner, partition, "AMICACHY")
        except InstallError:
            self.log_line.emit(
                f"Formatting {partition} failed; recreating the partition in-place."
            )
            partition = recreate_partition(runner, disk, partition)
            clear_filesystem_signatures(runner, partition)
            format_ext4(runner, partition, "AMICACHY")

        return {
            "root": partition,
            "efi": efi_part,
            "data": "INTERNAL", # Special value to indicate it's part of root
        }

    def run(self):
        runner = CommandRunner(log_callback=self.log_line.emit)
        try:
            self._do_install(runner)
            self.finished.emit(True, "")
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

        # Step 1: Prepare partitions
        self.step_changed.emit("Preparing storage...", 2)
        if self.state.is_partition:
            # When installing to a specific partition, we use it as root.
            # We still need an EFI partition. We'll try to find one on the same disk.
            # If not found, we'll error out for now or use the same partition (not ideal for UEFI).
            self.state.partitions = self._prepare_selected_partition(runner, device)
        else:
            self.state.partitions = partition_disk(runner, device)
        self.step_changed.emit("Storage prepared.", 10)

        # Step 2: Mount filesystems
        self.step_changed.emit("Mounting filesystems...", 12)
        mount_filesystems(runner, self.state.partitions)
        self.step_changed.emit("Filesystems mounted.", 15)

        # Step 3: Clone the live system (offline, no pacstrap/network needed)
        self.step_changed.emit("Copying AmiCachy from the live system...", 20)
        copy_live_system(runner)
        self.step_changed.emit("AmiCachy copied.", 70)

        # Step 5: Generate fstab
        self.step_changed.emit("Generating filesystem table...", 71)
        generate_fstab(runner)
        self.step_changed.emit("Filesystem table generated.", 72)

        # Step 6: Kernel payload
        self.step_changed.emit("Installing live kernel...", 73)
        install_live_kernel(runner)
        self.step_changed.emit("Live kernel installed.", 74)

        # Step 7: Configure system
        self.step_changed.emit("Configuring system...", 75)
        configure_system(runner)
        self.step_changed.emit("System configured.", 86)

        # Step 7b: Copy optional ROM/Kickstart files from the USB/live media
        self.step_changed.emit("Copying ROM files...", 87)
        copy_rom_payload(runner)

        # Step 8: Install bootloader
        self.step_changed.emit("Installing boot manager...", 88)
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
