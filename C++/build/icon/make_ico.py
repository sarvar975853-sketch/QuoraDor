# Packs a set of same-format PNGs into a valid .ico container.
# Modern Windows (Vista+) accepts PNG-compressed frames directly inside
# ICO files, so no bitmap re-encoding is needed -- just PNG bytes plus
# a small ICONDIR/ICONDIRENTRY header, per the ICO file format spec.
import struct, sys

def build_ico(png_paths, out_path):
    images = []
    for p in png_paths:
        with open(p, 'rb') as f:
            data = f.read()
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            raise ValueError(f"{p} is not a valid PNG")
        w = struct.unpack('>I', data[16:20])[0]
        h = struct.unpack('>I', data[20:24])[0]
        images.append((w, h, data))
    n = len(images)
    header = struct.pack('<HHH', 0, 1, n)
    entries = b''
    offset = 6 + 16 * n
    payload = b''
    for (w, h, data) in images:
        bw = w if w < 256 else 0
        bh = h if h < 256 else 0
        entries += struct.pack('<BBBBHHII', bw, bh, 0, 0, 1, 32, len(data), offset)
        payload += data
        offset += len(data)
    with open(out_path, 'wb') as f:
        f.write(header)
        f.write(entries)
        f.write(payload)

if __name__ == '__main__':
    build_ico(sys.argv[2:], sys.argv[1])
