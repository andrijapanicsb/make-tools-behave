# Running the fix: reference

This page is the reference for all ways to run the fix. If you are working inside Windows and have not done this before, use the [step-by-step guide](step-by-step.md) instead.

**What gets fixed:** one file. When VMware Tools was installed, Windows kept a copy of its installer package in `C:\Windows\Installer\` (a file with a random name such as `1a2b3c.msi`). The uninstall runs from that cached package, and the crashing helper DLLs are inside it. The fix changes a few bytes in those DLLs, inside that one `.msi` file. By default nothing else on the system is changed.

| Script | Use it when | What it does |
|---|---|---|
| [`scripts/Fix-VMwareToolsUninstall.ps1`](../scripts/Fix-VMwareToolsUninstall.ps1) | The VM is running Windows (the normal case). Run inside the guest (section 1) or from the KVM or Proxmox host through the QEMU guest agent (section 2). | Finds the cached VMware Tools `.msi` and fixes it in place, keeping a backup. |
| [`scripts/vmtfix.py`](../scripts/vmtfix.py) | Optional. You cannot or do not want to run anything inside Windows. | The same fix, run with Python 3 on a copy of that `.msi` file taken out of the VM (section 3). |

Both make the same change: each VMware backdoor instruction is replaced with one of the same length that returns what a non-VMware machine returns, so VMware's own "not on VMware" code path runs. Kernel drivers (`.sys`) are never touched. See the [README](../README.md) for the root cause and the exact bytes.

Take a snapshot or clone of the VM before you start. Test one VM before a fleet.

---

## 1. Inside the guest

The full walkthrough, with expected output, is in the [step-by-step guide](step-by-step.md). In short, in an elevated PowerShell:

```powershell
# 1. Report what would change. Nothing is written.
powershell -NoProfile -ExecutionPolicy Bypass -File C:\vmtools-fix\scripts\Fix-VMwareToolsUninstall.ps1 -DryRun

# 2. Patch the cached VMware Tools MSI. A backup is kept.
powershell -NoProfile -ExecutionPolicy Bypass -File C:\vmtools-fix\scripts\Fix-VMwareToolsUninstall.ps1

# 3. Find the VMware Tools product code.
$tools = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                          'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
         Where-Object DisplayName -eq 'VMware Tools'
$tools | Select-Object DisplayVersion, PSChildName

# 4. Uninstall.
$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/x $($tools.PSChildName) /quiet /norestart REBOOT=ReallySuppress /l*v C:\Windows\Temp\vmtools-uninstall.log"
$p.ExitCode
```

Expected results:

- Step 1 logs a `product:` line with the Tools version and the cached package, and an `MSI` line ending in `found (dry run)`.
- Step 2 logs one line per patched package, for example `MSI  C:\Windows\Installer\1a2b3c.msi: <n> DLL stream(s), <n> site(s), <n> byte(s) patched`, and ends with `done: 1 file(s) changed, <n> site(s)`.
- Running step 2 a second time reports `nothing to patch (already fixed, or no VMware custom-action DLLs)`. It is safe to repeat.
- The uninstall exits with **0** or **3010** (3010 means success, reboot required). Reboot when it suits you.
- If VMware Tools is not installed, the script says so and exits without changing anything.

The script always exits with code 0, also when it could not patch a file. In automation, check its output or log for the `patched` and `done:` lines (or `ERROR`), not its exit code.

### Options

| Option | What it does |
|---|---|
| `-DryRun` | Report only, write nothing. |
| `-InstalledFiles` | Also patch the user-mode EXE and DLL files in the VMware Tools program folder. Not needed for the uninstall. Useful only if you keep Tools installed on the new platform for a while and want its user-mode helpers to stop crashing. |
| `-Path <file>[,<file>]` | Patch these MSI, EXE or DLL files instead of finding the installed package. |
| `-NoBackup` | Do not keep backups. Not recommended. |
| `-BackupDir <dir>` | Where backups go. Default: `C:\Windows\Temp\vmtools-uninstall-fix-backup` |
| `-LogPath <file>` | Log file. Default: `C:\Windows\Temp\vmtools-uninstall-fix.log`. New runs are appended. |

The script needs Administrator or SYSTEM rights.

### Undo

Before a file is changed, it is copied to the backup folder as `<name>.orig`. An existing backup is never overwritten, so it always holds the original. To undo, copy it back over the patched file, for example:

```powershell
Copy-Item C:\Windows\Temp\vmtools-uninstall-fix-backup\1a2b3c.msi.orig C:\Windows\Installer\1a2b3c.msi -Force
```

---

## 2. From the KVM or Proxmox host (QEMU guest agent)

If the VM runs on KVM and has the QEMU guest agent (`qemu-ga`) installed and running, everything in section 1 can be done from the host. Many migration tools install the agent during conversion. The agent runs as SYSTEM and needs no guest credentials. The VMware Tools uninstaller does not stop it, so it remains available for the whole job.

> **Security note.** By default the QEMU guest agent gives the host full SYSTEM access to a Windows guest (root on Linux): it can read and write any file and run any program. That is what makes this section work. Once the migration work is done, consider locking the agent down to the commands you actually need, with an allow list (`--allow-rpcs`, or `--block-rpcs` for a block list, on the command line or in its configuration file).

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

Add `-DryRun` to the `arg` list for a report-only run first.

### Proxmox VE

```bash
VMID=106
# copy the script into the guest through the Proxmox agent API
pvesh create /nodes/$(hostname)/qemu/$VMID/agent/file-write \
  --file 'C:\Windows\Temp\Fix-VMwareToolsUninstall.ps1' \
  --content "$(cat scripts/Fix-VMwareToolsUninstall.ps1)"

# run it as SYSTEM and wait for the output
qm guest exec $VMID --timeout 300 -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Windows\Temp\Fix-VMwareToolsUninstall.ps1'
```

`qm guest exec` waits and prints the exit code and output.

### The uninstall step

Run the uninstall through the same channel. One way is to put steps 3 and 4 of section 1 into a small file, for example `uninstall-vmtools.ps1`:

```powershell
$tools = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                          'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
         Where-Object DisplayName -eq 'VMware Tools'
if (@($tools).Count -ne 1) { Write-Output "VMware Tools entries found: $(@($tools).Count)"; exit 1 }
$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/x $($tools.PSChildName) /quiet /norestart REBOOT=ReallySuppress /l*v C:\Windows\Temp\vmtools-uninstall.log"
exit $p.ExitCode
```

Copy it into the guest and run it exactly as the fix script above (`-File C:\Windows\Temp\uninstall-vmtools.ps1`). With Proxmox, use a longer `--timeout`, as the uninstall can take several minutes. The exit code is that of `msiexec`: 0 or 3010 means success.

If the agent refuses `guest-exec` or `guest-file-*` with "has been disabled", its command policy is locked down. In that case use section 1, or the first-boot step of your migration tool.

---

## 3. Optional: fix the file offline with `vmtfix.py`

This is only needed if you would rather not run a script inside Windows. Typical cases:

- **The VM is powered off** and you work on its disk from a Linux machine (for example a migration tool that adjusts the disk before the first boot on KVM).
- **You want to see exactly what will change** before touching a production VM. In report mode `vmtfix.py` lists every instruction it would change and writes nothing.

It makes the same change as the PowerShell script, to the same file: the cached VMware Tools `.msi` from the VM's `C:\Windows\Installer\` folder. Steps:

1. **Copy that `.msi` out of the VM's disk** to your Linux machine, with whatever disk tool you use. Keep its file name. To find which `.msi` is the VMware Tools one: it is the `LocalPackage` value under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\<packed-guid>\InstallProperties` for the product whose `DisplayName` is `VMware Tools`. On a running VM, the fix script's `-DryRun` output shows it as `package`.
2. **Run `vmtfix.py` on it:**

   ```bash
   # report only: what would change, nothing is written
   python3 scripts/vmtfix.py 1a2b3c.msi

   # write the fixed package as 1a2b3c.msi.fixed (the original is left untouched)
   python3 scripts/vmtfix.py --write 1a2b3c.msi
   ```

3. **Copy `1a2b3c.msi.fixed` back into the VM** as `C:\Windows\Installer\1a2b3c.msi` (same name, replacing the cached package). Keep the original as a backup.
4. **Uninstall VMware Tools** (section 1, steps 3 and 4) when the VM is running again.

`vmtfix.py` also accepts a single VMware Tools `.dll` or `.exe` instead of an `.msi`, to inspect or fix one program file on its own.

---

## Tested

- **End to end on KVM** (uninstall fails, fix applied, uninstall succeeds): Windows Server 2019 with VMware Tools 11.3.5 and 13.1.10. Once inside the guest, and once from the KVM host through the QEMU guest agent as SYSTEM with no guest login (uninstall exit code 3010).
- **No regressions:** Windows Server 2016, 2022 and 2025: fix applied, uninstall completed. (On these versions the helper crash does not turn into error 1603, so the uninstall did not fail before either.)
- **Analysed and emulated:** VMware Tools 10.3.5, 10.3.10, 12.0.0, 12.1.5, 12.5.6 and 13.1.10.
- The host-side runs above used Proxmox and pushed the script in base64 pieces through `guest-exec`. The single-call `guest-file-write` and `pvesh` copy commands use the same agent but were not part of those runs. The `uninstall-vmtools.ps1` example in section 2 was also not part of those runs.
