# Changelog

## v1.0.0 - 2026-11-27

First release.

### Added

- `scripts/Fix-VMwareToolsUninstall.ps1`: PowerShell script, run inside Windows as Administrator or SYSTEM. Finds the cached VMware Tools MSI in `C:\Windows\Installer\`, keeps a backup, and patches the VMware backdoor instructions in its custom-action DLLs in place. Options: `-DryRun`, `-InstalledFiles`, `-Path`, `-NoBackup`, `-BackupDir`, `-LogPath`.
- `scripts/vmtfix.py`: Python 3 script that makes the same change to a cached `.msi` (or a single `.dll`/`.exe`) copied out of the VM. Report-only by default; `--write` writes a `.fixed` copy.
- `docs/step-by-step.md`: step-by-step guide for running the fix and the uninstall inside Windows.
- `docs/choosing.md`: comparison of uninstalling VMware Tools before the migration with fixing and uninstalling it after.
- `docs/running.md`: reference for all script options, running from the KVM or Proxmox host through the QEMU guest agent, and the offline path with `vmtfix.py`.
- `docs/the-vmware-backdoor.md`: root-cause write-up.
- `examples/backdoor-poc.ps1`: proof of concept that reads host information through the backdoor as an unprivileged user, on VMware only.

### Tested

- End to end on KVM: Windows Server 2019 with VMware Tools 11.3.5 and 13.1.10, inside the guest and from the KVM host through the QEMU guest agent as SYSTEM with no guest login (uninstall exit code 3010).
- No regressions: Windows Server 2016, 2022 and 2025 (fix applied, uninstall completed).
- Analysed and emulated: VMware Tools 10.3.5, 10.3.10, 12.0.0, 12.1.5, 12.5.6 and 13.1.10.
