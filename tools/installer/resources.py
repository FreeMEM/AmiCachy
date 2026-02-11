"""Text constants, boot entry templates, and installation paths."""

MOUNTPOINT = "/mnt/amicachy"
CACHYOS_GPG_KEY = "882DCFE48E2051D48E2562ABF3B607488DB35A47"
INSTALLER_DATA_DIR = "/usr/share/amicachy/installer"
INSTALL_LOG_PATH = "/tmp/amicachy-install.log"

# Minimum disk size in bytes (20 GiB)
MIN_DISK_SIZE = 20 * 1024 * 1024 * 1024

BOOT_ENTRIES = {
    "classic_68k": {
        "filename": "01-classic-68k.conf",
        "title": "AmiCachyEnv - Classic 68k",
        "options": "root=LABEL=AMICACHY rw quiet splash loglevel=3 vt.global_cursor_default=0 amiprofile=classic_68k mitigations=off nowatchdog",
    },
    "ppc_nitro": {
        "filename": "02-ppc-nitro.conf",
        "title": "AmiCachyEnv - PPC Nitro",
        "options": "root=LABEL=AMICACHY rw quiet splash loglevel=3 vt.global_cursor_default=0 amiprofile=ppc_nitro mitigations=off nowatchdog",
    },
    "dev_station": {
        "filename": "03-dev-station.conf",
        "title": "AmiCachyEnv - Dev Station",
        "options": "root=LABEL=AMICACHY rw quiet splash loglevel=3 vt.global_cursor_default=0 amiprofile=dev_station",
    },
}

LOADER_CONF_TEMPLATE = """\
default {default_entry}
timeout 5
editor  no
console-mode max
"""

PROFILE_DISPLAY = {
    "classic_68k": {
        "name": "Classic 68k",
        "description": "Amiga 500/1200 emulation (68k processor)",
    },
    "ppc_nitro": {
        "name": "PPC Nitro",
        "description": "AmigaOS 4.1 PowerPC emulation (high performance)",
    },
    "dev_station": {
        "name": "Dev Station",
        "description": "Development workstation with code editor and Amiberry",
    },
}

WELCOME_TEXT = (
    "This will prepare your system as a dedicated Amiga workstation.\n\n"
    "\u2022 Your hardware will be analyzed for compatibility\n"
    "\u2022 You will choose a target drive and boot profiles\n"
    "\u2022 The system will be installed and configured automatically"
)

AMIGA_DIRS = [
    "kickstarts",
    "disks",
    "hdf",
    "os41/system",
    "os41/work",
]
