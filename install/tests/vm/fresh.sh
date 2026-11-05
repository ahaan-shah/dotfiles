#!/usr/bin/env bash
# fresh.sh <network> <bootloader> — wipe the test disk and run a real headless
# archinstall from the ISO. network: nm_iwd|nm|iso; bootloader: Limine|Systemd-boot|Grub.
# Ends powered off, frozen as the overlay "minimal". User tester, password test123.
set -u
cd "$(dirname "$0")"
./vm.py stop 2>/dev/null; sleep 1
./vm.py new
./vm.py iso
./vm.py expect 'archiso login:' 150
./vm.py serial root; sleep 3
K="$(cat "${VMTEST_DIR:-$HOME/.cache/hyprahaan-vmtest}/id_ed25519.pub")"
./vm.py serial "mkdir -p /root/.ssh; echo '$K' > /root/.ssh/authorized_keys; chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys"
sleep 3
SCP=(scp -q -i "${VMTEST_DIR:-$HOME/.cache/hyprahaan-vmtest}/id_ed25519" -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
"${SCP[@]}" archinstall-config.py root@127.0.0.1:/root/
./vm.py ssh root "cd /root && python archinstall-config.py '$1' '$2' tester test123 && (setsid nohup archinstall --config config.json --creds creds.json --silent --skip-version-check >/root/ai.log 2>&1 </dev/null &) ; sleep 1"
until ./vm.py ssh root 'tail -3 /root/ai.log | grep -cE "You may reboot|Error|Traceback" ' 2>/dev/null </dev/null | grep -qv '^0'; do sleep 10; done
./vm.py ssh root 'tail -4 /root/ai.log | sed "s/\x1b\[[0-9;?]*[a-zA-Z]//g" | cut -c1-120' </dev/null
./vm.py stop; sleep 2
./vm.py overlay minimal
echo minimal-frozen
