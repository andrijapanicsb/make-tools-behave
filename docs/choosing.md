# Which approach should I use?

When a Windows VM moves from VMware to another hypervisor (KVM, Proxmox, CloudStack, Hyper-V), VMware Tools has to be removed at some point. There are two ways to do it. Neither is perfect. This page sets out the trade-offs so you can choose.

## Option A: uninstall VMware Tools on VMware, before migrating

This is the common advice. On VMware the uninstaller works, because the hypervisor answers the calls that crash elsewhere.

**Advantages**

- Simplest. No extra tool, no edited files.
- Uses only VMware's own, unmodified uninstaller.

**Disadvantages**

- **It changes the source VM.** The VM you would fall back to is no longer the VM that was running before.
- **Rollback becomes harder.** If the migration fails and has to be rolled back, the Windows VM must boot on VMware again, but without the Tools drivers it was using: the VMware paravirtual SCSI controller (PVSCSI) for its disks, VMXNET3 for its network, and others. Depending on the VM's virtual hardware, it may not boot, or it may boot without network.
- To recover from that you need a snapshot or backup taken before the uninstall, or you must reinstall VMware Tools (which itself needs a working console session on the VM).
- It must be planned before the migration. It does not help VMs that have already been migrated with Tools still installed.

## Option B: migrate first, then fix and uninstall Tools on the target

This is what this repository is for. The VM is migrated with VMware Tools still installed. On the target, the cached Tools installer is patched and Tools is uninstalled.

**Advantages**

- **The source VM stays untouched.** A rollback to VMware is clean: the original VM still has all its drivers.
- Works for VMs that were already migrated with Tools still installed.
- The fix is run once, against one file on the migrated VM (the cached VMware Tools `.msi` in `C:\Windows\Installer\`). A backup of that file is kept.
- On KVM and Proxmox it can be run from the host through the QEMU guest agent, without a guest login.

**Disadvantages**

- **An extra step on the target.** You run the fix before the uninstall.
- **It edits a signed VMware file.** The Authenticode signature of the patched DLLs inside the `.msi` is no longer valid. Windows Installer still runs it, but security tools or policies that check signatures may notice.
- **It needs high privileges in the guest:** Administrator or SYSTEM, or the QEMU guest agent (which runs as SYSTEM).
- It is a community fix, not a vendor-supported procedure.

## Summary

| | A. Uninstall on VMware first | B. Migrate, then fix and uninstall |
|---|---|---|
| Source VM changed | Yes | No |
| Clean rollback to VMware | Only with a snapshot, backup or Tools reinstall | Yes |
| Extra tools needed | None | This script |
| Edits a signed VMware file | No | Yes (one cached `.msi`, backed up) |
| Works on already-migrated VMs | No | Yes |
| Rights needed | Admin in the guest on VMware | Admin or SYSTEM in the guest on the target, or the QEMU guest agent |

If keeping a clean rollback path matters more to you than avoiding an edited installer file, use option B. If you have a reliable snapshot of the source VM, and the rollback risk is acceptable, option A is simpler.

Whichever you choose, test it on one VM first.

To use option B, follow the [step-by-step guide](step-by-step.md).
