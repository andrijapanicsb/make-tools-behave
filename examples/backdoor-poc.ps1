<#
    backdoor-poc.ps1 — the VMware "backdoor", from an ordinary (non-admin) user inside a Windows guest.

    WHAT THIS SHOWS
      With ONE CPU instruction, unprivileged guest code reaches past the guest operating system and talks straight to
      the VMware hypervisor — no admin rights, no VMware software installed, no API, no driver. It reads host-provided
      facts about THIS VM (that it is on VMware, the VMware product type/version, the host CPU speed).

      The point is not the data. The point is the CHANNEL: it sits BELOW your OS's permission model. The guest OS never
      sees it and can't gate it. Same mechanism the VMware Tools uninstaller uses — and the same instruction that
      crashes with 0xC0000096 the moment the VM is no longer on VMware.

    WHAT THIS IS NOT
      This is NOT a VM escape. The backdoor is guest-initiated and host-serviced: the guest can only ask, and the
      hypervisor decides what to answer and enforces its own policy. It cannot read host memory, other VMs, or anything
      the hypervisor does not choose to expose. It only reads host-exposed info about this one VM.

    SAFE TO RUN ANYWHERE
      The script first uses the *safe* detection (CPUID leaf 0x40000000, which never faults) to check it is actually on
      VMware. It only does the backdoor knock if the answer is "VMwareVMware". Off VMware it prints a note and stops,
      instead of crashing — the exact seatbelt VMware forgot to put on its own uninstaller.

    Run:  powershell -ExecutionPolicy Bypass -File backdoor-poc.ps1      (any user; x64 Windows)
#>

$cs = @'
using System;
using System.Runtime.InteropServices;

public static class LowLevel {
    [DllImport("kernel32")] static extern IntPtr VirtualAlloc(IntPtr a, uint size, uint type, uint prot);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void RegFn(IntPtr regs);

    // in:  regs[0..3] = EAX,EBX,ECX,EDX    out: regs[0..3] = EAX,EBX,ECX,EDX after the instruction
    // (RCX holds the pointer on x64; RBX is saved/restored because the ABI requires it.)
    static uint[] Run(byte[] code, uint eax, uint ebx, uint ecx, uint edx) {
        IntPtr mem = VirtualAlloc(IntPtr.Zero, (uint)code.Length, 0x1000 | 0x2000, 0x40); // COMMIT|RESERVE, EXEC_RW
        Marshal.Copy(code, 0, mem, code.Length);
        RegFn fn = (RegFn)Marshal.GetDelegateForFunctionPointer(mem, typeof(RegFn));
        uint[] r = new uint[] { eax, ebx, ecx, edx };
        GCHandle h = GCHandle.Alloc(r, GCHandleType.Pinned);
        try { fn(h.AddrOfPinnedObject()); return (uint[])r.Clone(); } finally { h.Free(); }
    }

    // push rbx; mov r8,rcx; mov eax,[r8]; xor ecx,ecx; cpuid; store eax,ebx,ecx,edx; pop rbx; ret
    static readonly byte[] CPUID = {
        0x53, 0x49,0x89,0xC8, 0x41,0x8B,0x00, 0x31,0xC9, 0x0F,0xA2,
        0x41,0x89,0x00, 0x41,0x89,0x58,0x04, 0x41,0x89,0x48,0x08, 0x41,0x89,0x50,0x0C, 0x5B, 0xC3 };

    // push rbx; mov r8,rcx; load eax,ebx,ecx,edx; IN eax,dx; store eax,ebx,ecx,edx; pop rbx; ret
    static readonly byte[] BDOOR = {
        0x53, 0x49,0x89,0xC8,
        0x41,0x8B,0x00, 0x41,0x8B,0x58,0x04, 0x41,0x8B,0x48,0x08, 0x41,0x8B,0x50,0x0C,
        0xED,
        0x41,0x89,0x00, 0x41,0x89,0x58,0x04, 0x41,0x89,0x48,0x08, 0x41,0x89,0x50,0x0C, 0x5B, 0xC3 };

    // The safe check VMware's own uninstaller should have used: CPUID hypervisor brand (never faults).
    public static string HypervisorBrand() {
        uint[] r = Run(CPUID, 0x40000000, 0, 0, 0);
        byte[] b = new byte[12];
        BitConverter.GetBytes(r[1]).CopyTo(b, 0);  // EBX
        BitConverter.GetBytes(r[2]).CopyTo(b, 4);  // ECX
        BitConverter.GetBytes(r[3]).CopyTo(b, 8);  // EDX
        return System.Text.Encoding.ASCII.GetString(b).TrimEnd('\0', ' ');
    }

    // The backdoor knock. cmd = command number (10 = GETVERSION, 1 = GETMHZ, ...).
    public static uint[] Backdoor(uint cmd) {
        return Run(BDOOR, 0x564D5868 /* "VMXh" */, 0, cmd, 0x5658 /* port "VX" */);
    }
}
'@

Add-Type -TypeDefinition $cs -Language CSharp

Write-Host "=== VMware backdoor PoC (unprivileged guest -> hypervisor) ===" -ForegroundColor Cyan
Write-Host ("Running as: {0}  (no admin required)" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)

# 1) The SAFE way to tell if we're on VMware: CPUID. Never faults, works everywhere.
$brand = [LowLevel]::HypervisorBrand()
Write-Host ("`nCPUID hypervisor brand (leaf 0x40000000): '{0}'" -f $brand)

if ($brand -ne 'VMwareVMware') {
    Write-Host "`nNot a VMware VM -> NOT performing the backdoor knock." -ForegroundColor Yellow
    Write-Host "On non-VMware hardware the 'in eax,dx' instruction is privileged and would crash this process"
    Write-Host "with 0xC0000096 (STATUS_PRIVILEGED_INSTRUCTION) -- which is exactly the VMware Tools uninstaller bug."
    return
}

# 2) We're on VMware -> knock on the backdoor. GETVERSION (command 0x0A).
$VMXh = 0x564D5868
$v = [LowLevel]::Backdoor(10)
Write-Host "`nBackdoor GETVERSION (EAX='VMXh', ECX=0x0A, port 0x5658):" -ForegroundColor Green
if ($v[1] -eq $VMXh) {
    Write-Host "  -> the hypervisor answered: EBX echoed the 'VMXh' magic. This VM IS on VMware."
    Write-Host ("     version word (EAX): 0x{0:X8}   product type (ECX): {1}" -f $v[0], $v[2])
} else {
    Write-Host ("  -> unexpected EBX 0x{0:X8} (magic not echoed)" -f $v[1])
}

# 3) Another host-only fact an unprivileged guest has no business reading: host CPU speed. GETMHZ (command 1).
$m = [LowLevel]::Backdoor(1)
Write-Host ("`nBackdoor GETMHZ (ECX=0x01): host CPU speed ~ {0} MHz" -f $m[0]) -ForegroundColor Green

Write-Host "`nNo admin. No VMware software. No OS API. One instruction." -ForegroundColor Cyan
Write-Host "That is the backdoor: a channel that sits below your guest OS's permission model."

<#
    GOING FURTHER (not implemented here): the high-bandwidth channel on port 0x5659 ("VY") carries GuestRPC. Through it,
    an unprivileged guest can run commands like  info-get guestinfo.<key>  and read values the host/admin placed on the
    VM -- including, in many real deployments, cloud-init / OVF provisioning payloads that contain PASSWORDS. VMware even
    ships a tool that does this for you (vmware-rpctool / VMwareToolboxCmd). The lesson for operators: never put a secret
    in guestinfo, and never assume the guest OS's permissions protect it -- the backdoor doesn't ask the OS.
#>
