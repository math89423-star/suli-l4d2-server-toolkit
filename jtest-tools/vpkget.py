#!/usr/bin/env python3
"""最小 VPK 读取器: 从单文件 VPK 抽取指定文件(处理 preload/主档数据 + LZMA)"""
import struct, sys, os

def read_vpk_tree(path):
    with open(path, 'rb') as f:
        sig, ver, treesz = struct.unpack('<III', f.read(12))
        assert sig == 0x55AA1234, f"not vpk: {sig:08x}"
        if ver == 2:
            f.read(16)  # archiveMD5SectionSize,Offset, otherCRC Size,Offset
            data_base = 28 + treesz
        else:
            data_base = 12 + treesz

        def cstr():
            b = bytearray()
            while True:
                c = f.read(1)
                if c in (b'\x00', b''): break
                b += c
            return b.decode('utf-8', 'replace')

        entries = {}
        ext = cstr()
        while ext:
            p = cstr()
            while p:
                name = cstr()
                while name:
                    crc, pre, aidx, eoff, elen = struct.unpack('<IHHII', f.read(16))
                    term = f.read(2)
                    preload = f.read(pre) if pre else b''
                    entries[f"{p}/{name}.{ext}" if ext else f"{p}/{name}"] = (aidx, eoff, elen, preload)
                    name = cstr()
                p = cstr()
            ext = cstr()
    return entries, data_base

def extract(vpk, want):
    entries, data_base = read_vpk_tree(vpk)
    matches = {k: v for k, v in entries.items() if want.lower() in k.lower()}
    for k, (aidx, eoff, elen, preload) in matches.items():
        print(f"# FOUND {k} len={elen} preload={len(preload)} archive={aidx}", file=sys.stderr)
        if aidx == 0x7FFF:
            # 单档 vpk / dir 档: 数据在本文件数据区 data_base+eoff(preload 为前缀时先补)
            with open(vpk, 'rb') as f:
                f.seek(data_base + eoff)
                data = f.read(elen)
            if preload:
                data = (preload + data)[:elen]
        elif aidx == 0:
            with open(vpk, 'rb') as f:
                f.seek(data_base + eoff)
                data = f.read(elen) if not preload else None
                if data is None:
                    data = (preload + f.read(elen - len(preload)))[:elen] if False else f.read(elen)
                # 单档 vpk: entryOffset 相对数据区; 有 preload 时先补 preload 再读剩余
        else:
            base = os.path.splitext(vpk)[0]
            apath = f"{base}_{aidx:03d}.vpk"
            with open(apath, 'rb') as f:
                f.seek(eoff)
                data = f.read(elen)
        if preload and len(data) < elen:
            data = preload + data
        yield k, data

def maybe_lzma(data):
    # Valve LZMA: magic "LZMA"(0x414D5A4C LE) + int actualSize + int lzSize + props...
    if len(data) > 17 and data[:4] == b'LZMA':
        import lzma
        actual = struct.unpack('<I', data[8:12])[0]
        dec = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE)
        out = dec.decompress(data[17:])
        return out[:actual]
    return data

if __name__ == '__main__':
    vpk, want, outp = sys.argv[1], sys.argv[2], sys.argv[3]
    for k, data in extract(vpk, want):
        data = maybe_lzma(data)
        with open(outp, 'wb') as f:
            f.write(data)
        print(f"# wrote {outp} ({len(data)} bytes)", file=sys.stderr)
        break
