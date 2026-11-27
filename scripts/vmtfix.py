#!/usr/bin/env python3
"""vmtfix: make VMware "backdoor" I/O instructions harmless in VMware Tools binaries (x86 and x64 PE files).

Outside VMware, `in eax,dx` / `rep insb` / `rep outsb` on ports 0x5658/0x5659 raise a privileged-instruction
fault (0xC0000096) in user mode. Each site is replaced, in place and with the same length, by code that returns
what a machine without the backdoor would return: EAX = 0xFFFFFFFF (low-bandwidth call) or EBX = 0 (high-bandwidth
status "failed"). Callers then take their own "not on VMware / RPC failed" paths.
"""
import re, sys, hashlib, struct
# (name, regex over code bytes, offset of patched bytes inside the match, old bytes, new bytes)
RULES = [
    # hand-written stub Backdoor_InOut:   mov rax,[rax] ; in eax,dx ; xchg [rsp],rax     (x64)
    ('InOut-x64',  rb'\x48\x8b\x00\xed(?=\x48\x87\x04\x24)', 0, b'\x48\x8b\x00\xed', b'\x83\xc8\xff\x90'),   # or eax,-1 ; nop
    # same stub, 32-bit:                  mov eax,[eax] ; in eax,dx ; xchg [esp],eax
    ('InOut-x86',  rb'(?<!\x48)\x8b\x00\xed(?=\x87\x04\x24)', 0, b'\x8b\x00\xed', b'\x83\xc8\xff'),          # or eax,-1
    # high-bandwidth stubs:               mov ?ax,[?ax] ; cld ; rep insb / rep outsb
    ('HbIn',       rb'(?<=\x8b\x00\xfc)\xf3\x6c', 0, b'\xf3\x6c', b'\x31\xdb'),                               # xor ebx,ebx
    ('HbOut',      rb'(?<=\x8b\x00\xfc)\xf3\x6e', 0, b'\xf3\x6e', b'\x31\xdb'),                               # xor ebx,ebx
    # inline probes:                      mov dx,0x5658 ; in eax,dx
    ('Inline',     rb'\x66\xba\x58\x56\xed', 0, b'\x66\xba\x58\x56\xed', b'\x83\xc8\xff\x66\x90'),            # or eax,-1 ; 2-byte nop
]
# anything that still looks like a backdoor I/O instruction after patching (review list)
LEFT = rb'\x66\xba[\x58\x59]\x56.{0,12}?(?:\xed|\xef|\xf3\x6c|\xf3\x6e)|\x8b\x00\xed\x87\x04\x24|\x8b\x00\xfc\xf3[\x6c\x6e]'
def pe_code_ranges(b):
    """(file offset, size) of executable sections; raises ValueError if b is not a PE image."""
    if b[:2] != b'MZ': raise ValueError('not MZ')
    e = struct.unpack_from('<I', b, 0x3c)[0]
    if b[e:e + 4] != b'PE\0\0': raise ValueError('not PE')
    nsec = struct.unpack_from('<H', b, e + 6)[0]; opt = struct.unpack_from('<H', b, e + 20)[0]
    out = []; s = e + 24 + opt
    for i in range(nsec):
        vsz, va, rsz, rptr = struct.unpack_from('<IIII', b, s + 40 * i + 8)
        ch = struct.unpack_from('<I', b, s + 40 * i + 36)[0]
        if ch & 0x20000000 and rsz: out.append((rptr, rsz))
    return out
def is_native(b):
    """True for kernel drivers / native images (PE Subsystem 1). They run in ring 0, where the I/O instructions do
    not fault, and they are signature-checked at load: they must never be modified."""
    e = struct.unpack_from('<I', b, 0x3c)[0]
    return struct.unpack_from('<H', b, e + 24 + 68)[0] == 1
def find(b):
    """list of (file offset, rule name, old, new) for a PE image given as bytes."""
    hits = []
    if is_native(b): return hits
    for off, size in pe_code_ranges(b):
        code = b[off:off + size]
        for name, rx, rel, old, new in RULES:
            for m in re.finditer(rx, code, re.S):
                p = off + m.start() + rel
                assert b[p:p + len(old)] == old
                hits.append((p, name, old, new))
    return sorted(hits)
def leftovers(b):
    res = []
    for off, size in pe_code_ranges(b):
        for m in re.finditer(LEFT, b[off:off + size], re.S): res.append((off + m.start(), b[off + m.start():off + m.end()].hex()))
    return res
def patch(b):
    b = bytearray(b); hits = find(bytes(b))
    for p, name, old, new in hits: b[p:p + len(old)] = new
    return bytes(b), hits
def fix_checksum(b):
    """recompute the PE header checksum (drivers and some loaders check it; harmless otherwise)."""
    b = bytearray(b); e = struct.unpack_from('<I', b, 0x3c)[0]; co = e + 24 + 64
    struct.pack_into('<I', b, co, 0)
    s = 0
    data = bytes(b) + (b'\0' if len(b) % 2 else b'')
    for (w,) in struct.iter_unpack('<H', data):
        s += w; s = (s & 0xffff) + (s >> 16)
    s = (s & 0xffff) + (s >> 16)
    struct.pack_into('<I', b, co, (s + len(b)) & 0xffffffff)
    return bytes(b)
# ---------------- MSI / OLE compound file: patch PE streams in place ----------------
ENDOFCHAIN, FREESECT = 0xFFFFFFFE, 0xFFFFFFFF
class Cfb:
    def __init__(self, data):
        self.d = data
        if data[:8] != bytes.fromhex('D0CF11E0A1B11AE1'): raise ValueError('not an OLE compound file')
        self.ss = 1 << struct.unpack_from('<H', data, 0x1E)[0]
        self.cutoff = struct.unpack_from('<I', data, 0x38)[0]
        nfat = struct.unpack_from('<I', data, 0x2C)[0]
        difat = list(struct.unpack_from('<109I', data, 0x4C))
        nxt, ndif = struct.unpack_from('<II', data, 0x44)
        per = self.ss // 4
        while nxt not in (ENDOFCHAIN, FREESECT) and ndif > 0:
            ent = struct.unpack_from('<%dI' % per, data, self.off(nxt))
            difat += ent[:-1]; nxt = ent[-1]; ndif -= 1
        self.fat = []
        for s_ in difat[:nfat]:
            if s_ in (ENDOFCHAIN, FREESECT): continue
            self.fat += struct.unpack_from('<%dI' % per, data, self.off(s_))
        self.dirstart = struct.unpack_from('<I', data, 0x30)[0]
    def off(self, sect): return (sect + 1) * self.ss
    def chain(self, start):
        out = []; s_ = start
        while s_ not in (ENDOFCHAIN, FREESECT):
            if s_ >= len(self.fat) or len(out) > len(self.fat): raise ValueError('bad FAT chain')
            out.append(s_); s_ = self.fat[s_]
        return out
    def entries(self):
        """(name, type, start sector, size) for every directory entry"""
        for s_ in self.chain(self.dirstart):
            o = self.off(s_)
            for i in range(0, self.ss, 128):
                e = self.d[o + i:o + i + 128]
                nl = struct.unpack_from('<H', e, 0x40)[0]
                if not nl: continue
                yield (e[:max(nl - 2, 0)].decode('utf-16le', 'replace'), e[0x42], struct.unpack_from('<I', e, 0x74)[0], struct.unpack_from('<Q', e, 0x78)[0] if self.ss == 4096 else struct.unpack_from('<I', e, 0x78)[0])
    def big_streams(self):
        for name, typ, start, size in self.entries():
            if typ == 2 and size >= self.cutoff: yield name, self.chain(start), size
    def read(self, sectors, size):
        return b''.join(self.d[self.off(s_):self.off(s_) + self.ss] for s_ in sectors)[:size]
def msi_name(n):
    """decode an MSI stream name (for display)"""
    cs = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._'; out = ''
    for ch in n:
        c = ord(ch)
        if 0x3800 <= c < 0x4800: c -= 0x3800; out += cs[c & 0x3f] + cs[(c >> 6) & 0x3f]
        elif 0x4800 <= c < 0x4840: out += cs[c - 0x4800]
        elif c == 0x4840: out += '!'
        else: out += ch
    return out
def patch_msi(data):
    """returns (new bytes, report) - every user-mode PE stream in the compound file is patched in place"""
    cfb = Cfb(bytes(data)); out = bytearray(data); rep = []
    for name, sectors, size in cfb.big_streams():
        st = cfb.read(sectors, size)
        if st[:2] != b'MZ': continue
        try: hits = find(st)
        except ValueError: continue
        for p, rule, old, new in hits:
            for k, nb in enumerate(new):
                so = p + k; fo = cfb.off(sectors[so // cfb.ss]) + so % cfb.ss
                assert out[fo] == old[k]; out[fo] = nb
        rep.append((msi_name(name), size, hashlib.sha256(st).hexdigest(), [(p, r) for p, r, _, _ in hits]))
    return bytes(out), rep
if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser(); ap.add_argument('files', nargs='+'); ap.add_argument('--write', action='store_true', help='write FILE.fixed next to each file')
    a = ap.parse_args()
    for f in a.files:
        b = open(f, 'rb').read()
        if b[:8] == bytes.fromhex('D0CF11E0A1B11AE1'):
            nb, rep = patch_msi(b)
            print(f"{f}: MSI sha256 {hashlib.sha256(b).hexdigest()[:16]} PE streams {len(rep)} patched sites {sum(len(h) for *_, h in rep)}")
            for name, size, sha, hits in rep: print(f"   {name:<70} {size:>8} {sha[:16]} sites {len(hits)}")
            if a.write: open(f + '.fixed', 'wb').write(nb); print('   wrote', f + '.fixed', hashlib.sha256(nb).hexdigest()[:16])
            continue
        try: nb, hits = patch(b)
        except ValueError as ex: print(f'{f}: skipped ({ex})'); continue
        left = leftovers(nb)
        print(f"{f}: sha256 {hashlib.sha256(b).hexdigest()[:16]} sites {len(hits)} left {len(left)}")
        for p, name, old, new in hits: print(f"   {p:#09x} {name:<10} {old.hex()} -> {new.hex()}")
        for p, hx in left: print(f"   LEFT {p:#09x} {hx}")
        if a.write and hits:
            nb = fix_checksum(nb); open(f + '.fixed', 'wb').write(nb); print('   wrote', f + '.fixed', hashlib.sha256(nb).hexdigest()[:16])
