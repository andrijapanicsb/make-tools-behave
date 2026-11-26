# The VMware "backdoor" — the full story

Because "backdoor" is a loaded word, the honest answer is: yes, it's literally called the backdoor, but not in the
scary sense. Here's the full story.

## It's a real thing, and "backdoor" is the actual name

VMware's own engineers named it. The open-source VMware Tools (open-vm-tools) has files and functions called exactly
this — `backdoor.c`, `Backdoor_InOut`, `Backdoor_HbIn`. So this isn't editorialising; "backdoor" is the term of art.

But here "backdoor" means a **private service entrance between the guest and the hypervisor** — not a secret way to
bypass a login. It's a designed, intentional channel. Think of it as a hidden intercom in the wall of the VM: the guest
can buzz the hypervisor, and on VMware someone buzzes back.

## How the knock works

The guest loads three magic values into CPU registers and executes one I/O instruction:

- **EAX = 0x564D5868** — that's the ASCII "**VMXh**" (V, M, X, h). The password.
- **DX = 0x5658** — the port, ASCII "**VX**". The door number.
- **ECX = a command** — e.g. `0x0A` = "what VMware version am I on?", `0x1E` = "open an RPC channel."
- Then: **`in eax, dx`** — read from that port.

On VMware, the hypervisor is watching port 0x5658. It sees the "VMXh" password, realises this isn't real hardware I/O —
it's a backdoor request — and answers in the registers (version, RPC data, whatever). There's a higher-bandwidth sibling
on port 0x5659 ("VY") using `rep ins`/`rep outs` for bulk transfer (that's the GuestRPC pipe). This is how Tools does
*everything* host-related: time sync, copy-paste, "shutting down now," reading VMX settings, the heartbeat vCenter shows.

## Why it detonates off VMware — and why that's the bug

`in`/`out` are **privileged instructions**. A normal user-mode program is not allowed to touch I/O ports. On real
hardware (or KVM/Hyper-V), the CPU sees a ring-3 program trying to do I/O and raises a fault → Windows reports
**0xC0000096, STATUS_PRIVILEGED_INSTRUCTION** → the process dies.

On VMware it never faults, because the hypervisor specifically makes that port access "work" from user mode. **VMware's
magic is the only thing stopping that instruction from being illegal.** Take VMware away and the instruction is just…
a crime the CPU refuses to commit.

And here's the idiocy worth pointing at: in the uninstaller, the instruction that crashes is often the one asking **"am
I even on VMware?"** (command `0x0A`, GETVERSION). The check for whether it's safe to talk to VMware *is itself* the
unsafe thing. It faults instead of answering "no."

The maddening part: a **safe** check exists and VMware knows it — `CPUID` leaf `0x40000000` returns the string
"VMwareVMware" and never faults. Their own code has a careful `VmCheck_IsVirtualWorld` that does CPUID first, inside a
guard. They just… don't use it on the uninstaller's crashing path. They reach straight for the raw backdoor with no
seatbelt.

## Is it a *security* backdoor?

Not in the malicious sense — it's by design, guest-initiated, host-serviced (the guest can only ask; the host decides
what to answer). Two honest caveats, though:

- Malware uses it as a **VM-detection trick**: "try the VMXh knock; if something answers, I'm in a VMware VM, so hide."
  That's a real, well-known use.
- Over the years, **bugs in how the host handled backdoor/RPC commands have caused VM-escape CVEs**. So the channel is
  security-*relevant* and hardened shops sometimes disable parts of it — but the door existing is intentional, not a
  planted exploit.

## Receipts: the CVEs

Not hand-waving — the guest-to-host channel has a long public rap sheet. A few, grouped by how directly they hit the
backdoor/RPC command handling (primary sources only):

**The literal backdoor / RPC-command-handling bugs**

- **CVE-2012-1516** — the host VMX process mishandles RPC commands (ESX/ESXi 3.5-4.1): guest user -> DoS or possible
  host code execution (VMSA-2012-0009). <https://nvd.nist.gov/vuln/detail/CVE-2012-1516>
- **CVE-2012-1517** — uninitialized memory in the VMware *backdoor interface* itself (`ghi.guest.trashFolder.state`).
  Same advisory. Honest caveat: the advisory calls a full escape *possible but not publicly proven*.
  <https://nvd.nist.gov/vuln/detail/CVE-2012-1517>

**Demonstrated guest-to-host RCE over RPC-backed features (drag-and-drop / copy-paste ride the same channel)**

- **CVE-2017-4901** — drag-and-drop out-of-bounds write, guest-to-host code execution, CVSS 9.9 (VMSA-2017-0005,
  shown at Pwn2Own 2017). <https://nvd.nist.gov/vuln/detail/CVE-2017-4901>
- **CVE-2017-4905** — uninitialized read in the backdoor callback handler (same advisory family).
- **CVE-2016-7461** — drag-and-drop/copy-paste RPC flaw; a full guest-to-host patch analysis was published publicly.

**The modern anchor — actively exploited in the wild (2025)**

VMSA-2025-0004 (March 2025): three guest-to-hypervisor zero-days, exploited in the wild, one later used in ransomware.

- **CVE-2025-22224** — TOCTOU -> out-of-bounds write, code execution as the VMX host process, CVSS 9.3.
- **CVE-2025-22225** — arbitrary kernel write -> sandbox escape (confirmed in ransomware activity).
- **CVE-2025-22226** — HGFS information leak of VMX process memory.
  <https://nvd.nist.gov/vuln/detail/CVE-2025-22224>

Precision note: 22224/22225 are VMCI/kernel-write bugs rather than the *legacy* backdoor port specifically, but they
are the same "guest reaches into the host over a guest-host channel" family. The 2012 and 2017 entries are the literal
backdoor/RPC-handler bugs. Point stands: this channel is security-*relevant*, which is exactly why hardened shops lock
parts of it down — the door being there is intentional, the bugs in how the host answered through it were not.


## What I actually saw (so this isn't hand-waving)

In the disassembly, the crashing stub literally does: load EAX="VMXh", DX=0x5658, ECX=command, `in eax,dx`. For Tools
13.1.10 the fatal call is ECX=`0x0A` (GETVERSION — "am I on VMware?"). For 11.3.5 it's ECX=`0x1E`, opening an RPC
channel to ship the install log to the host. The fix replaces the `in` with "return 0xFFFFFFFF" — i.e. it makes the
guest get the exact answer a non-VMware machine *should* give ("no VMware here"), so VMware's own "not on VMware" path
runs instead of crashing.

So: a real backdoor, real magic port, real ASCII passwords — and an uninstaller that bangs on the door so carelessly it
knocks itself out when nobody's home.
