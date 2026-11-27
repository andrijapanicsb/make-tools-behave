# Running the fix

**What gets fixed:** one file. When VMware Tools was installed, Windows kept a copy of its installer package in `C:\Windows\Installer\` (a file with a random name like `1a2b3c.msi`). The uninstall runs from that cached package, and the crashing helper DLLs are inside it. The fix changes a few bytes in those DLLs, inside that one `.msi` file. By default nothing else on the system is changed.

**Most people need only the PowerShell script.** It runs inside Windows, finds that cached `.msi` by itself, fixes it in place and keeps a backup. Sections 1 and 2 below.

| Script | Use it when | What it does |
|---|---|---|
| [`scripts/Fix-VMwareToolsUninstall.ps1`](../scripts/Fix-VMwareToolsUninstall.ps1) | **the normal case:** the VM is running Windows | finds the cached VMware Tools `.msi` and fixes it in place |
| [`scripts/vmtfix.py`](../scripts/vmtfix.py) | **optional:** you cannot or don't want to run anything inside Windows | the same fix, done from Linux (or any OS with Python 3) on that `.msi` file after you have copied it out of the VM. Section 3. |

Both make the same change: each VMware "backdoor" instruction is replaced with one of the same length that returns what a non-VMware machine returns, so VMware's own "not on VMware" code path runs. Kernel drivers (`.sys`) are never touched. See the [README](../README.md) for the root cause and the exact bytes.

Take a snapshot or clone of the VM before you start. Test one VM before a fleet.

---

## 1. Inside the guest (any way you can get an elevated PowerShell)

Copy `Fix-VMwareToolsUninstall.ps1` into the guest, for example to `C:\Windows\Temp\`, then in an **elevated** PowerShell:

```powershell
cd C:\Windows\Temp

# 1. See what it would change. Nothing is written.
powershell -ExecutionPolicy Bypass -File .\Fix-VMwareToolsUninstall.ps1 -DryRun

# 2. Patch the cached VMware Tools MSI (a backup is kept).
powershell -ExecutionPolicy Bypass -File .\Fix-VMwareToolsUninstall.ps1

# 3. Find the VMware Tools product code.
$tools = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                          'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
         Where-Object DisplayName -eq 'VMware Tools'
$tools | Select-Object DisplayVersion, PSChildName

# 4. Uninstall as usual.
Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/x $($tools.PSChildName) /quiet /norestart REBOOT=ReallySuppress /l*v C:\Windows\Temp\vmtools-uninstall.log"
```

Expected results:

- Step 2 logs one line per patched package, for example `MSI  C:\Windows\Installer\1a2b3c.msi: 8 DLL stream(s), ... site(s), ... byte(s) patched`, and ends with `done: 1 file(s) changed`.
- Running step 2 a second time reports `nothing to patch (already fixed ...)`. It is safe to repeat.
- The uninstall exits with **0** or **3010** (3010 = success, reboot required). Reboot when it suits you.
- If VMware Tools is not installed, the script says so and exits without changing anything.

### Options

| Option | What it does |
|---|---|
| `-DryRun` | report only, write nothing |
| `-InstalledFiles` | also patch the user-mode EXE/DLL files in the VMware Tools program folder (not needed for the uninstall; useful if you keep Tools installed for a while on KVM and want its user-mode helpers to stop crashing) |
| `-Path <file>[,<file>]` | patch these MSI/EXE/DLL files instead of finding the installed package |
| `-NoBackup` | do not keep backups (not recommended) |
| `-BackupDir <dir>` | where backups go; default `C:\Windows\Temp\vmtools-uninstall-fix-backup` |
| `-LogPath <file>` | log file; default `C:\Windows\Temp\vmtools-uninstall-fix.log` |

### Undo

Every changed file is copied first to the backup folder as `<name>.orig`. To undo, copy it back over the patched file, for example:

```powershell
Copy-Item C:\Windows\Temp\vmtools-uninstall-fix-backup\1a2b3c.msi.orig C:\Windows\Installer\1a2b3c.msi -Force
```

---

## 2. From the KVM host, with no guest login (QEMU guest agent)

If the VM runs on KVM and has the QEMU guest agent (`qemu-ga`) installed, which most migration tools install during conversion, you can do all of the above from the host. The agent runs as SYSTEM and needs no guest credentials. The VMware Tools uninstaller does not stop it, so it is a reliable channel for the whole job.

### libvirt (`virsh`)

```bash
VM=my-windows-vm
PS1='C:\\Windows\\Temp\\Fix-VMwareToolsUninstall.ps1'

# copy the script into the guest
H=$(virsh qemu-agent-command "$VM" "{\"execute\":\"guest-file-open\",\"arguments\":{\"path\":\"$PS1\",\"mode\":\"wb\"}}" | grep -o '[0-9]\+')
virsh qemu-agent-command "$VM" "{\"execute\":\"guest-file-write\",\"arguments\":{\"handle\":$H,\"buf-b64\":\"$(base64 -w0 scripts/Fix-VMwareToolsUninstall.ps1)\"}}"
virsh qemu-agent-command "$VM" "{\"execute\":\"guest-file-close\",\"arguments\":{\"handle\":$H}}"

# run it as SYSTEM (returns a pid)
virsh qemu-agent-command "$VM" "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"powershell.exe\",\"arg\":[\"-NoProfile\",\"-ExecutionPolicy\",\"Bypass\",\"-File\",\"$PS1\"],\"capture-output\":true}}"

# read the result (repeat until "exited":true); out-data is base64
virsh qemu-agent-command "$VM" '{"execute":"guest-exec-status","arguments":{"pid":1234}}'
```

Then run the uninstall the same way: `guest-exec` with `powershell.exe` and the step 3 and 4 commands from section 1, or put those lines at the end of a copy of the script.

### Proxmox VE

```bash
VMID=106
# copy the script into the guest through Proxmox's agent API
pvesh create /nodes/$(hostname)/qemu/$VMID/agent/file-write \
  --file 'C:\Windows\Temp\Fix-VMwareToolsUninstall.ps1' \
  --content "$(cat scripts/Fix-VMwareToolsUninstall.ps1)"

# run it as SYSTEM and wait for the output
qm guest exec $VMID --timeout 300 -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Windows\Temp\Fix-VMwareToolsUninstall.ps1'
```

`qm guest exec` waits and prints the exit code and output for you.

If the agent refuses `guest-exec` or `guest-file-*` with "has been disabled", its command policy is locked down. In that case use section 1, or the first-boot step of your migration tool.

---

## 3. Optional: fix the file from Linux instead of inside Windows

You only need this if you would rather not run a script inside Windows. Typical cases:

- **The VM is powered off** and you work on its disk from a Linux machine (for example a migration tool that adjusts the disk before the first boot on KVM).
- **You want to see exactly what will change** before touching a production VM. In report mode `vmtfix.py` lists every instruction it would change and writes nothing.

It does the same fix as the PowerShell script, to the same file: the cached VMware Tools `.msi` from the VM's `C:\Windows\Installer\` folder. The steps:

1. **Copy that `.msi` out of the VM's disk** to your Linux machine, with whatever disk tool you use. Keep its file name. (To find which `.msi` is the VMware Tools one: it is the package listed under "VMware Tools" in the Windows uninstall registry, `LocalPackage` value; on a running VM, section 1 step 3 shows it too.)
2. **Run `vmtfix.py` on it:**

   ```bash
   # report only: what would change, nothing is written
   python3 scripts/vmtfix.py 1a2b3c.msi

   # write the fixed package as 1a2b3c.msi.fixed (the original is left untouched)
   python3 scripts/vmtfix.py --write 1a2b3c.msi
   ```

3. **Copy `1a2b3c.msi.fixed` back into the VM** as `C:\Windows\Installer\1a2b3c.msi` (same name, replacing the cached package).
4. **Uninstall VMware Tools as usual** (section 1 step 4), whenever the VM is running again.

`vmtfix.py` also accepts a single VMware Tools `.dll` or `.exe` instead of an `.msi`, if you want to inspect or fix one program file on its own.

---

## Tested

- **End to end on KVM** (uninstall fails, fix applied, uninstall succeeds): Windows Server 2019 with VMware Tools 11.3.5 and 13.1.10. Once inside the guest, and once from the KVM host through the QEMU guest agent as SYSTEM with no guest login (uninstall exit code 3010).
- **No regressions:** Windows Server 2016, 2022 and 2025: fix applied, uninstall completed. (On these versions the helper crash does not turn into error 1603, so the uninstall did not fail before either.)
- **Analysed and emulated:** VMware Tools 10.3.5, 10.3.10, 12.0.0, 12.1.5, 12.5.6 and 13.1.10.
- The host-side runs above used Proxmox and pushed the script in base64 pieces through `guest-exec`. The single-call `guest-file-write` and `pvesh` copy commands use the same agent but were not part of those runs.
