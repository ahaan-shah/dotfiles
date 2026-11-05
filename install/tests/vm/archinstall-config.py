#!/usr/bin/env python3
"""Runs on the Arch ISO. Writes the JSON archinstall needs for a headless
"minimal" install, because that is what the one-line installer assumes it starts
from. The disk half comes from archinstall's own suggest_single_disk_layout(),
the only way to get one it accepts (map: "What a VM run found").

Usage: archinstall-config.py <network-type> <bootloader> <user> <password>
Test-only additions to a real minimal install: openssh + sshd, so the harness
has a way in. The key is added by custom_commands; nothing in the installer
depends on either."""
import asyncio, json, sys
from pathlib import Path
from archinstall.lib.disk.device_handler import device_handler
from archinstall.lib.disk.disk_menu import suggest_single_disk_layout
from archinstall.lib.models.device import DiskLayoutConfiguration, DiskLayoutType, FilesystemType

net, boot, user, pw = sys.argv[1:5]
pub = Path("/root/.ssh/authorized_keys").read_text().strip()
dev = device_handler.get_device(Path("/dev/vda"))
mod = asyncio.run(suggest_single_disk_layout(dev, filesystem_type=FilesystemType.EXT4, separate_home=False))
disk = DiskLayoutConfiguration(config_type=DiskLayoutType.Default, device_modifications=[mod])
cfg = {
    "disk_config": disk.json(),
    "profile_config": {"profile": {"main": "Minimal"}},
    "bootloader_config": {"bootloader": boot, "uki": False, "removable": True},
    "network_config": {"type": net},
    "hostname": "vmtest", "kernels": ["linux"], "timezone": "Asia/Kolkata",
    "locale_config": {"kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8"},
    "swap": {"enabled": True, "algorithm": "zstd"}, "ntp": True,
    "packages": ["openssh"], "services": ["sshd"],
    "custom_commands": [
        f"mkdir -p /home/{user}/.ssh /root/.ssh; echo '{pub}' | tee /home/{user}/.ssh/authorized_keys > /root/.ssh/authorized_keys;"
        f" chown -R {user}:{user} /home/{user}/.ssh; chmod 700 /home/{user}/.ssh /root/.ssh;"
        f" chmod 600 /home/{user}/.ssh/authorized_keys /root/.ssh/authorized_keys"
    ],
}
creds = {"users": [{"username": user, "!password": pw, "sudo": True, "groups": []}]}
Path("/root/config.json").write_text(json.dumps(cfg, indent=1, default=str))
Path("/root/creds.json").write_text(json.dumps(creds))
print("written")
