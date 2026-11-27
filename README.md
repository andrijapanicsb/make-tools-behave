# make-tools-behave

A fix that lets the VMware Tools uninstaller work on Windows VMs after they have been migrated off VMware.

> After a Windows VM is moved from VMware to KVM, Proxmox, CloudStack or Hyper-V, VMware Tools often cannot be uninstalled. The uninstaller's helper code asks the hypervisor "am I on VMware?" with a CPU instruction that only works on VMware. Anywhere else that instruction faults, the helper crashes, and on Windows Server 2019 the removal fails with error 1603. This repository patches those few instructions in your own cached copy of the Tools installer, so the uninstaller takes its normal "not on VMware" path and completes.

**New to this? Start here: [step-by-step guide](docs/step-by-step.md).**
Not sure whether you need this at all? Read [Which approach should I use?](docs/choosing.md)

---

## Summary

- **Symptom:** VMware Tools will not uninstall after a VM is migrated off VMware (KVM, Proxmox, CloudStack, Hyper-V). On Windows Server 2019 the removal fails with **`1603`**. On 2016, 2022 and 2025 the uninstall continues, but a helper process crashes silently.
- **Root cause:** the uninstaller's custom actions call the VMware **backdoor** (`in eax, dx` on port `0x5658`) to talk to the hypervisor. They do this without any guard. Off VMware the instruction is not allowed in user mode, it raises `0xC0000096` (`STATUS_PRIVILEGED_INSTRUCTION`), and the custom action crashes. One of the crashing calls is the "am I on VMware?" check itself.
- **Fix:** replace each of those instructions, in place and with the same length, with one that returns `0xFFFFFFFF`. That is the value a non-VMware machine returns. VMware's own "not on VMware" code path then runs and the removal completes. The change is 2 to 5 bytes per site, about 100 to 130 bytes per package.
- **What it is not:** it is not a VMware binary and it does not modify kernel drivers. It edits the copy of the installer that is already cached on your machine.

A detailed write-up of the mechanism: [docs/the-vmware-backdoor.md](docs/the-vmware-backdoor.md).

---

## Which approach should I use?

There are two ways to deal with VMware Tools during a migration. Neither is perfect.

- **A. Uninstall VMware Tools on VMware, before migrating.** This is the common advice and the simplest. But it changes the source VM. If the migration has to be rolled back, the VM must boot on VMware again without the Tools drivers it was using (PVSCSI storage, VMXNET3 network). It can then fail to boot or come up without network, and you need a snapshot, a backup, or a Tools reinstall to recover.
- **B. Migrate first, then fix and uninstall Tools on the target (this repository).** The source VM stays untouched, so a rollback stays clean. The downsides: an extra step on the target, it edits a signed VMware file, and it needs Administrator or SYSTEM rights in the guest (or the QEMU guest agent).

The full comparison is in [docs/choosing.md](docs/choosing.md).

---

## The bug in detail

VMware Tools talks to the hypervisor through the **backdoor**: it loads `EAX = 0x564D5868` ("VMXh"), `DX = 0x5658` ("VX"), `ECX = <command>`, then executes `in eax, dx`. On VMware the hypervisor intercepts that port and answers in the registers. Everywhere else, `in` and `out` are privileged I/O instructions that a user-mode (ring 3) process may not execute. The CPU faults and Windows reports `0xC0000096`.

![One instruction, two outcomes: on VMware the hypervisor answers; anywhere else the same instruction faults](docs/img/vmware-backdoor-lanes.png)

The uninstaller runs several **MSI custom actions** that use this channel. Depending on the Tools generation, the one that crashes is either:

- **`VM_LogStart`** (Tools 10.3 to 12.1.x): opens an RPC channel (`ECX = 0x1E`) to send the install log to the host, or
- **`VM_CheckRequirements`** (Tools 12.5 and later, 13.x): the version probe itself (`ECX = 0x0A`, GETVERSION, "am I on VMware?").

The check that decides whether it is safe to talk to VMware is itself the unsafe operation. It faults instead of returning "no". Only Windows Server 2019 turns that crashed custom action into a fatal `1603`. The other versions continue the uninstall without the crashed action.

---

## The fix: exactly what changes

The patch finds every backdoor I/O site in the installer's custom-action code. It replaces the instruction that reads from the port with one that loads `0xFFFFFFFF` into `EAX`. That is what real hardware returns from an unhandled I/O port. The "VMXh" magic is therefore never returned, VMware's own detection concludes "not on VMware", and its normal fallback path runs.

| Site | Before (reads the port) | After (returns "not VMware") |
|---|---|---|
| Standard backdoor read (x64) | `… in eax, dx` | `or eax, -1 ; nop` |
| Standard backdoor read (x86) | `… in eax, dx` | `or eax, -1` |
| High-bandwidth in/out (`rep ins`/`rep outs`, port `0x5659`) | `rep ins`/`rep outs` | `xor ebx, ebx` (status "failed") |
| Inline version probe | `mov dx, 0x5658 ; in eax, dx` | `or eax, -1 ; nop` |

- 2 to 5 bytes per site, about 100 to 130 bytes per package. No logic is removed.
- The all-ones answer is what a non-VMware host returns, so every code path that runs afterwards is one VMware already wrote.

### Which files it touches

- The patch targets the **cached copy of the VMware Tools MSI** in the guest, `C:\Windows\Installer\<random>.msi`. It does not touch `Program Files` or the running services (unless you ask for that with `-InstalledFiles`).
- Inside that MSI (an OLE compound file) the custom-action helpers are stored as embedded streams in the **Binary** table: two DLLs, `_toolsinstutil.dll` and `_instutils.dll`, each embedded several times (one stream per custom-action component and architecture). That is about **eight** streams in a typical package. The patch rewrites the instruction bytes in place in each of them.
- After patching, the DLL's Authenticode signature no longer matches. This is expected for an edited binary. Windows Installer still loads and runs it, so the uninstall proceeds.
- **Kernel-mode drivers (`.sys`) are never touched.** Only user-mode installer helper code is patched. The VMXNET3, PVSCSI and memory-control drivers are left as they are.

---

## Running it

| Guide | For |
|---|---|
| [docs/step-by-step.md](docs/step-by-step.md) | Running the fix inside Windows, explained from the beginning. Start here if you have not done this before. |
| [docs/running.md](docs/running.md) | Reference: all script options, running from the KVM or Proxmox host through the QEMU guest agent, and fixing the file offline from Linux with `vmtfix.py`. |

The scripts:

- [`scripts/Fix-VMwareToolsUninstall.ps1`](scripts/Fix-VMwareToolsUninstall.ps1): PowerShell, run inside Windows as Administrator or SYSTEM. It finds the cached VMware Tools MSI, keeps a backup, and patches it in place. Use `-DryRun` first to see what it would change.
- [`scripts/vmtfix.py`](scripts/vmtfix.py): optional, Python 3. Makes the same change to a cached `.msi` file that you have copied out of the VM.

In short, inside the guest:

1. Run `Fix-VMwareToolsUninstall.ps1 -DryRun`, then `Fix-VMwareToolsUninstall.ps1`.
2. Run the normal uninstall: `msiexec /x {PRODUCT-CODE} /quiet /norestart REBOOT=ReallySuppress`.
3. Reboot.

On Windows Server 2019, where the uninstall previously failed with `1603`, the removal then completes on the first attempt.

If the VM runs on KVM or Proxmox and has the QEMU guest agent, the same steps can be run from the host as SYSTEM, without a guest login. See [docs/running.md, section 2](docs/running.md#2-from-the-kvm-or-proxmox-host-qemu-guest-agent).

---

## Proof of concept: the backdoor from an unprivileged user

[`examples/backdoor-poc.ps1`](examples/backdoor-poc.ps1) is a small, self-contained demo. Run as an ordinary, non-admin user inside a Windows guest on VMware, it calls the backdoor with a single instruction and reads facts that the host provides about the VM (that it is on VMware, the product version, the host CPU speed).

It is not a VM escape: the guest can only ask, and the hypervisor decides what to answer. It is safe to run anywhere. It uses the non-faulting `CPUID` check first and only calls the backdoor when it is actually on VMware. Off VMware it prints a note instead of crashing. That `CPUID` check is the guard that is missing from VMware's own uninstaller.

---

## Scope and safety

- **It patches your own installed copy.** This repository contains no VMware code or binaries. You run it against the Tools package that is already on your machine.
- **No kernel drivers are modified**, only the user-mode MSI custom-action helpers.
- **A backup is kept** of every changed file (`<name>.orig`), so the change can be undone.
- **Test before a fleet.** Snapshot or clone one VM, confirm a clean removal, then roll out.
- Editing a signed binary invalidates its signature. This is expected and does not stop Windows Installer from running it.
- Removing VMware Tools before you migrate is also a valid approach, with its own trade-offs. See [docs/choosing.md](docs/choosing.md).

---

## Tested

- **End to end on KVM** (uninstall fails, fix applied, uninstall succeeds): Windows Server 2019 with VMware Tools 11.3.5 and 13.1.10. Once inside the guest, and once from the KVM host through the QEMU guest agent as SYSTEM with no guest login (uninstall exit code 3010).
- **No regressions:** Windows Server 2016, 2022 and 2025: fix applied, uninstall completed.
- **Analysed and emulated:** VMware Tools 10.3.5, 10.3.10, 12.0.0, 12.1.5, 12.5.6 and 13.1.10.

Details in [docs/running.md](docs/running.md#tested).

---

## Contents

- Root-cause write-up: [docs/the-vmware-backdoor.md](docs/the-vmware-backdoor.md)
- Choosing an approach: [docs/choosing.md](docs/choosing.md)
- Step-by-step guide: [docs/step-by-step.md](docs/step-by-step.md)
- Reference for all run paths: [docs/running.md](docs/running.md)
- In-guest PowerShell patcher: [scripts/Fix-VMwareToolsUninstall.ps1](scripts/Fix-VMwareToolsUninstall.ps1)
- Offline patcher for a copied `.msi`: [scripts/vmtfix.py](scripts/vmtfix.py)
- Backdoor proof of concept: [examples/backdoor-poc.ps1](examples/backdoor-poc.ps1)
- Changes per release: [CHANGELOG.md](CHANGELOG.md)

---

## License

[MIT](LICENSE). Keep the copyright notice. There is no warranty: this tool edits binaries, so test it on a copy first.
