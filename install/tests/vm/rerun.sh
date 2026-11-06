#!/usr/bin/env bash
# rerun.sh <logname> [install.sh args] — type the one-liner on the guest's logged-in
# console, as a person would, and answer sudo. Run log: ~tester/<logname> in the guest.
# The one line now asks three questions after sudo: pass --yes (or --no-aur and
# friends) for an unattended run, or answer them with `./vm.py type n; ./vm.py keys ret`.
cd "$(dirname "$0")"
log="$1"; shift
./vm.py type "script -qf $log -c 'curl -fsSL http://10.0.2.2:8765/install/bootstrap.sh | HYPRAHAAN_REPO=git://10.0.2.2:9418/mirror bash -s -- $*'"; ./vm.py keys ret
sleep 8; ./vm.py type "${VMTEST_PW:-test123}"; ./vm.py keys ret
