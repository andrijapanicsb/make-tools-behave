# Step by step: remove VMware Tools from a migrated Windows Server VM

This guide is for someone who has not done this before. It covers one VM, working inside Windows. Every command can be copied and pasted.

**What you will do:**

1. Open PowerShell as Administrator.
2. Put the fix script on the VM and check that it is the right file.
3. See which VMware Tools is installed.
4. Run the fix in test mode (`-DryRun`), then for real.
5. Uninstall VMware Tools.
6. Reboot and check that VMware Tools is gone.

It takes about 15 minutes. The uninstall itself can take a few minutes and shows no progress.

**Before you start:**

- The VM has already been migrated (to KVM, Proxmox, CloudStack, Hyper-V or similar), and it boots and has network on the new platform with that platform's drivers. This guide does not cover drivers.
- **Take a snapshot or backup of the VM.** If anything goes wrong you can go back.
- You need an account with Administrator rights in Windows.
- If you have many VMs, do one first and check the result before doing the rest.

Not sure whether this is the right approach for you? See [Which approach should I use?](choosing.md)

---

## Step 1. Open PowerShell as Administrator

Use one of these two ways:

- Click **Start**, type `PowerShell`. In the results, right-click **Windows PowerShell** and choose **Run as administrator**. Click **Yes** if Windows asks for permission.
- Or press **Win + X** and choose **Windows PowerShell (Admin)** (on some versions: **Terminal (Admin)**).

Check that the window title starts with **Administrator:**. If it does not, close it and try again. Every command in this guide must be run in this elevated window.

> On Windows Server Core (no Start menu), type `powershell` in the command window and press Enter. To check that the window is elevated, run `whoami /groups | findstr S-1-16-12288`. If it prints a line (`Mandatory Label\High Mandatory Level`), the window is elevated.

---

## Step 2. Put the script on the VM

### 2a. Download and extract the release

The release is a zip file: `make-tools-behave-v1.0.0.zip`, on the [v1.0.0 release page](https://github.com/andrijapanicsb/make-tools-behave/releases/tag/v1.0.0).

If the VM has internet access, download and extract it with these commands:

```powershell
New-Item -ItemType Directory -Path C:\vmtools-fix -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri https://github.com/andrijapanicsb/make-tools-behave/releases/download/v1.0.0/make-tools-behave-v1.0.0.zip -OutFile C:\vmtools-fix\make-tools-behave-v1.0.0.zip
Unblock-File C:\vmtools-fix\make-tools-behave-v1.0.0.zip
Expand-Archive C:\vmtools-fix\make-tools-behave-v1.0.0.zip -DestinationPath C:\vmtools-fix -Force
Get-ChildItem C:\vmtools-fix -Recurse | Unblock-File
```

If the VM has no internet access, download the zip on another computer and copy it into the VM (for example through a file share or a Remote Desktop drive). Put it in `C:\vmtools-fix\`, then run only the last three commands above.

The script is now at:

```
C:\vmtools-fix\scripts\Fix-VMwareToolsUninstall.ps1
```

`Unblock-File` removes the "downloaded from the internet" mark that Windows puts on downloaded files, so PowerShell does not refuse to run them.

### 2b. Check that the script is the right file

```powershell
Get-FileHash C:\vmtools-fix\scripts\Fix-VMwareToolsUninstall.ps1 -Algorithm SHA256
```

Compare the `Hash` value with the SHA-256 for `Fix-VMwareToolsUninstall.ps1` published in the release notes on the [release page](https://github.com/andrijapanicsb/make-tools-behave/releases/tag/v1.0.0). Upper or lower case does not matter. Every character must match. If it does not match, stop and download the file again.

---

## Step 3. See which VMware Tools is installed

Copy and paste:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
    Where-Object DisplayName -eq 'VMware Tools' |
    Select-Object DisplayName, DisplayVersion, PSChildName
```

You should see one line, for example:

```
DisplayName  DisplayVersion   PSChildName
-----------  --------------   -----------
VMware Tools <version>       {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}
```

- `DisplayVersion` is the installed VMware Tools version.
- `PSChildName` is the **product code**. It is used for the uninstall in step 5.

If nothing is shown, VMware Tools is not installed (as a Windows Installer product) and there is nothing to do.

**Optional:** to see which cached installer file will be patched, run:

```powershell
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products' |
    ForEach-Object { Get-ItemProperty (Join-Path $_.PSPath 'InstallProperties') -ErrorAction SilentlyContinue } |
    Where-Object DisplayName -eq 'VMware Tools' |
    Select-Object DisplayName, DisplayVersion, LocalPackage
```

`LocalPackage` is the cached `.msi` file in `C:\Windows\Installer\` (it has a random name). You do not have to run this: the script prints the same information in step 4.

---

## Step 4. Run the fix

### 4a. Test run (changes nothing)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\vmtools-fix\scripts\Fix-VMwareToolsUninstall.ps1 -DryRun
```

`-ExecutionPolicy Bypass` lets this one script run without changing the system's PowerShell policy.

Good output looks like this. Each line starts with the time in UTC. `<version>` and `<n>` stand for your VMware Tools version and the counts the script reports; the `.msi` file name will also differ.

```
2026-11-27T10:15:02Z start: user Administrator, dry run True, installed files False
2026-11-27T10:15:02Z product: VMware Tools <version>, package C:\Windows\Installer\1a2b3c.msi, location C:\Program Files\VMware\VMware Tools\
2026-11-27T10:15:04Z MSI  C:\Windows\Installer\1a2b3c.msi: <n> DLL stream(s), <n> site(s), <n> byte(s) found (dry run)
2026-11-27T10:15:04Z done: 1 file(s) changed, <n> site(s)
```

What to look for:

- The `product:` line shows the VMware Tools version and the `package` (the cached `.msi`) that will be patched.
- The `MSI` line ends with **`found (dry run)`**. This means the script found the instructions to patch. Nothing was written.
- In a test run, `done: 1 file(s) changed` means one file *would* be changed.

### 4b. Real run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\vmtools-fix\scripts\Fix-VMwareToolsUninstall.ps1
```

Good output looks like this (same placeholders as above):

```
2026-11-27T10:16:10Z start: user Administrator, dry run False, installed files False
2026-11-27T10:16:10Z product: VMware Tools <version>, package C:\Windows\Installer\1a2b3c.msi, location C:\Program Files\VMware\VMware Tools\
2026-11-27T10:16:12Z MSI  C:\Windows\Installer\1a2b3c.msi: <n> DLL stream(s), <n> site(s), <n> byte(s) patched
2026-11-27T10:16:12Z done: 1 file(s) changed, <n> site(s)
```

What to look for:

- The `MSI` line ends with **`patched`**.
- The last line starts with **`done: 1 file(s) changed`**.
- A backup of the original file was saved as `C:\Windows\Temp\vmtools-uninstall-fix-backup\<name>.msi.orig`.

If you run this command again, it reports `nothing to patch (already fixed, or no VMware custom-action DLLs)` and `done: 0 file(s) changed, 0 site(s)`. That is normal. It is safe to run the script more than once.

---

## Step 5. Uninstall VMware Tools

Copy and paste the whole block:

```powershell
$tools = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                          'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
         Where-Object DisplayName -eq 'VMware Tools'
if (@($tools).Count -ne 1) {
    "Expected exactly one VMware Tools entry, found $(@($tools).Count). Stop and check step 3."
} else {
    "Product code: $($tools.PSChildName)"
    $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/x $($tools.PSChildName) /quiet /norestart REBOOT=ReallySuppress /l*v C:\Windows\Temp\vmtools-uninstall.log"
    "Exit code: $($p.ExitCode)"
}
```

This runs the normal VMware Tools uninstall, the same as:

```
msiexec /x {product-code} /quiet /norestart REBOOT=ReallySuppress /l*v C:\Windows\Temp\vmtools-uninstall.log
```

It runs without any window (`/quiet`), does not restart the VM by itself (`/norestart REBOOT=ReallySuppress`), and writes a detailed log to `C:\Windows\Temp\vmtools-uninstall.log`. Wait until `Exit code:` is printed. This can take a few minutes.

- **Exit code 0**: success.
- **Exit code 3010**: success; a reboot is needed to finish.
- Any other code: the uninstall did not complete. See "If something goes wrong" below.

---

## Step 6. Reboot and check

Reboot the VM:

```powershell
Restart-Computer
```

After the reboot, open PowerShell as Administrator again (step 1) and run:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
    Where-Object DisplayName -eq 'VMware Tools'
Get-Service VMTools -ErrorAction SilentlyContinue
```

If VMware Tools is gone, **both commands print nothing**.

You can also check in **Programs and Features** (press **Win + R**, type `appwiz.cpl`, press Enter): **VMware Tools** should no longer be in the list.

The folder `C:\vmtools-fix\` can now be deleted. You can keep the backup in `C:\Windows\Temp\vmtools-uninstall-fix-backup\` until you are sure everything is fine, then delete it too.

---

## If something goes wrong

**Logs**

- The fix script's log: `C:\Windows\Temp\vmtools-uninstall-fix.log`. It contains the same lines the script printed. New runs are added to the end.
- The uninstall log: `C:\Windows\Temp\vmtools-uninstall.log`. It is long. To find the first failing step, search it for `Return value 3`:

  ```powershell
  Select-String -Path C:\Windows\Temp\vmtools-uninstall.log -Pattern 'Return value 3' -Context 20,0
  ```

**Messages from the fix script**

| Message | Meaning and what to do |
|---|---|
| `VMware Tools is not installed (no MSI product named "VMware Tools"): nothing to do` | The script did not find VMware Tools. If step 3 does show VMware Tools, check that the PowerShell window is elevated (title starts with **Administrator:**) and run the script again. |
| `cached MSI package not found` | Windows no longer has the cached installer file for VMware Tools. The fix needs that file, so it cannot help here. Restoring a missing cached package is outside the scope of this guide. |
| `nothing to patch (already fixed, or no VMware custom-action DLLs)` | The file was already patched earlier. Continue with step 5. |
| `... NOT patched: ...` or `ERROR <file>: <message>` | The file could not be read or written. Read the message. A common cause is a PowerShell window that is not elevated. |

**Undo the fix**

The script copied the original file to the backup folder before changing it. To put the original back, copy it over the patched file. Use the file name from the `package` part of the script output, for example:

```powershell
Copy-Item C:\Windows\Temp\vmtools-uninstall-fix-backup\1a2b3c.msi.orig C:\Windows\Installer\1a2b3c.msi -Force
```

Undo only matters before the uninstall. Once VMware Tools has been uninstalled, there is nothing left to undo.

**Running it again**

The script is safe to run again. It only changes instructions that have not been changed yet, and it never overwrites an existing backup, so the backup always holds the original file.

If you cannot solve the problem, restore the VM from the snapshot you took before you started.

For other ways to run the fix (from the KVM or Proxmox host, or offline from Linux) and all script options, see [running.md](running.md).
