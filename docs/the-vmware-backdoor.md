# The VMware "backdoor"

"Backdoor" is a loaded word. In this case it is the actual name of the mechanism, but it does not mean a hidden way to bypass security. This page explains what it is, why it crashes the uninstaller off VMware, and how the fix works.

## It is a real mechanism, and "backdoor" is its actual name

VMware's own engineers named it. The open-source VMware Tools (open-vm-tools) has files and functions called exactly
this: `backdoor.c`, `Backdoor_InOut`, `Backdoor_HbIn`. "Backdoor" is the established term.

Here "backdoor" means a **private service channel between the guest and the hypervisor**, not a secret way to bypass a
login. It is a designed, intentional channel. The guest sends a request through it, and on VMware the hypervisor
answers.

## How a backdoor call works

The guest loads three values into CPU registers and executes one I/O instruction:

- **EAX = 0x564D5868**: the ASCII string "**VMXh**" (V, M, X, h). A magic value that identifies the request.
- **DX = 0x5658**: the I/O port, ASCII "**VX**".
- **ECX = a command**: for example `0x0A` = "which VMware version am I on?", `0x1E` = "open an RPC channel".
- Then: **`in eax, dx`**, a read from that port.

On VMware, the hypervisor intercepts port 0x5658. It sees the "VMXh" value, recognises a backdoor request rather than
real hardware I/O, and answers in the registers (version, RPC data, and so on). A higher-bandwidth variant on port
0x5659 ("VY") uses `rep ins`/`rep outs` for bulk transfer (the GuestRPC channel). VMware Tools uses this channel for
most host-related functions: time sync, copy and paste, shutdown notifications, reading VMX settings, and the heartbeat
that vCenter shows.

## Why it crashes off VMware, and why that is the bug

`in` and `out` are **privileged instructions**. A normal user-mode program is not allowed to access I/O ports. On real
hardware, or on KVM or Hyper-V, the CPU sees a ring 3 program attempting I/O and raises a fault. Windows reports
**0xC0000096, STATUS_PRIVILEGED_INSTRUCTION**, and the process ends.

On VMware it does not fault, because the hypervisor deliberately allows that port access from user mode. Without
VMware, the instruction is simply not permitted.

In the uninstaller, the instruction that crashes is often the one that asks **"am I on VMware?"** (command `0x0A`,
GETVERSION). The check that decides whether it is safe to talk to VMware is itself the unsafe operation. It faults
instead of returning "no".

A safe check exists: `CPUID` leaf `0x40000000` returns the string "VMwareVMware" and never faults. VMware's own code
has a function, `VmCheck_IsVirtualWorld`, that runs the CPUID check first, inside a guard. The uninstaller's crashing
path does not use it; it calls the raw backdoor directly, without a guard.

## Is it a security backdoor?

Not in the malicious sense. It is by design, initiated by the guest and serviced by the host (the guest can only ask;
the host decides what to answer). There are two caveats:

- Malware uses it as a **VM-detection technique**: "try the VMXh request; if something answers, this is a VMware VM."
  This is a well-known use.
- Over the years, **bugs in how the host handled backdoor and RPC commands have led to VM-escape CVEs**. The channel is
  therefore security-relevant, and hardened environments sometimes disable parts of it. The channel itself is
  intentional, not a planted exploit.

## The CVEs

The guest-to-host channel has a public record of vulnerabilities. A selection, grouped by how directly they involve
the backdoor and RPC command handling (primary sources only):

**Backdoor and RPC command-handling bugs**

- **CVE-2012-1516**: the host VMX process mishandles RPC commands (ESX/ESXi 3.5-4.1): a guest user can cause a denial
  of service or possibly host code execution (VMSA-2012-0009). <https://nvd.nist.gov/vuln/detail/CVE-2012-1516>
- **CVE-2012-1517**: uninitialized memory in the VMware *backdoor interface* itself (`ghi.guest.trashFolder.state`).
  Same advisory. The advisory describes a full escape as possible but not publicly demonstrated.
  <https://nvd.nist.gov/vuln/detail/CVE-2012-1517>

**Demonstrated guest-to-host code execution over RPC-based features (drag-and-drop and copy-paste use the same channel)**

- **CVE-2017-4901**: drag-and-drop out-of-bounds write, guest-to-host code execution, CVSS 9.9 (VMSA-2017-0005,
  demonstrated at Pwn2Own 2017). <https://nvd.nist.gov/vuln/detail/CVE-2017-4901>
- **CVE-2017-4905**: uninitialized read in the backdoor callback handler (same advisory family).
- **CVE-2016-7461**: drag-and-drop/copy-paste RPC flaw; a full guest-to-host patch analysis was published.

**Recent: exploited in the wild (2025)**

VMSA-2025-0004 (March 2025): three guest-to-hypervisor zero-days, exploited in the wild, one later used in ransomware.

- **CVE-2025-22224**: TOCTOU leading to an out-of-bounds write, code execution as the VMX host process, CVSS 9.3.
- **CVE-2025-22225**: arbitrary kernel write leading to a sandbox escape (confirmed in ransomware activity).
- **CVE-2025-22226**: HGFS information leak of VMX process memory.
  <https://nvd.nist.gov/vuln/detail/CVE-2025-22224>

Note: CVE-2025-22224 and CVE-2025-22225 are VMCI and kernel-write bugs rather than bugs in the legacy backdoor port
specifically. They belong to the same class: the guest reaching into the host over a guest-host channel. The 2012 and
2017 entries are the backdoor and RPC-handler bugs. The conclusion is the same: this channel is security-relevant,
which is why hardened environments restrict parts of it. The channel is intentional; the bugs in how the host handled
it were not.

## What the disassembly shows

In the disassembly, the crashing stub loads EAX="VMXh", DX=0x5658, ECX=command, and executes `in eax,dx`. For Tools
13.1.10 the failing call is ECX=`0x0A` (GETVERSION, "am I on VMware?"). For 11.3.5 it is ECX=`0x1E`, which opens an RPC
channel to send the install log to the host. The fix replaces the `in` with an instruction that returns 0xFFFFFFFF.
The guest then gets the same answer a non-VMware machine gives ("no VMware here"), and VMware's own "not on VMware"
path runs instead of crashing.
