#!/usr/bin/env python3
"""테스트용 가구 생성기 출력 vs 커밋본 비교 (SE-059; SE-051 리뷰 후속 A).

사용:
    python3 -I tools/assets/compare_test_furniture.py <생성기 출력 루트> <커밋본 루트>

생성기 출력의 `<id>/` 폴더마다 같은 이름의 커밋본 폴더와 비교한다(커밋본 루트에 다른 에셋 폴더가 더 있어도 무시).
- `.glb`·`META.json`·`lint.json` 등 PNG 가 아닌 파일: 바이트 비교(첫 차이 오프셋 출력).
- `*.png`: 디코드한 픽셀 비교(첫 차이 위치 출력). zlib 압축 수준·청크 분할·필터 선택이 달라도 같은 픽셀이면 통과 —
  러너의 zlib 버전에 묶이지 않는다.
- 폴더 안 파일 목록이 다르면(한쪽에만 있는 파일) 차이로 본다.
차이가 하나라도 있으면 파일·위치를 출력하고 exit 1, 없으면 exit 0. 표준 라이브러리만 쓴다.
"""
import struct
import sys
import zlib
from pathlib import Path

PNG_SIG = b"\x89PNG\r\n\x1a\n"
_CHANNELS = {2: 3, 6: 4}  # 컬러 타입 → 채널 수 (8비트, 비인터레이스만 지원)


def decode_png(data):
    """8비트 RGB/RGBA 비인터레이스 PNG → (너비, 높이, 채널 수, 픽셀 bytes). 필터 0~4 전부 처리."""
    if data[:8] != PNG_SIG:
        raise ValueError("PNG 시그니처가 아님")
    pos, idat, ihdr = 8, bytearray(), None
    while pos + 8 <= len(data):
        n, tag = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8:pos + 8 + n]
        if tag == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
        pos += 12 + n
    if ihdr is None:
        raise ValueError("IHDR 없음")
    w, h, depth, ctype, _comp, _filt, interlace = ihdr
    if depth != 8 or ctype not in _CHANNELS or interlace:
        raise ValueError(f"지원하지 않는 PNG 형식(depth={depth}, color={ctype}, interlace={interlace})")
    ch = _CHANNELS[ctype]
    stride = w * ch
    raw = zlib.decompress(bytes(idat))
    if len(raw) != h * (stride + 1):
        raise ValueError(f"IDAT 길이 불일치: {len(raw)} != {h * (stride + 1)}")
    out = bytearray()
    prev = bytearray(stride)
    for y in range(h):
        ft = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if ft == 1:
            for i in range(ch, stride):
                line[i] = (line[i] + line[i - ch]) & 255
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(stride):
                left = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                b = prev[i]
                c = prev[i - ch] if i >= ch else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 255
        elif ft != 0:
            raise ValueError(f"알 수 없는 PNG 필터 {ft} (행 {y})")
        out += line
        prev = line
    return w, h, ch, bytes(out)


def first_byte_diff(a, b):
    """두 bytes 의 첫 차이 오프셋(길이만 다르면 짧은 쪽 길이). 같으면 None."""
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return None if len(a) == len(b) else n


def compare_png(a_path, b_path):
    """같은 픽셀이면 None, 아니면 차이 설명 문자열."""
    try:
        wa, ha, ca, pa = decode_png(Path(a_path).read_bytes())
        wb, hb, cb, pb = decode_png(Path(b_path).read_bytes())
    except (ValueError, zlib.error, struct.error) as e:
        return f"PNG 디코드 실패: {e}"
    if (wa, ha, ca) != (wb, hb, cb):
        return f"크기·채널 다름: {wa}x{ha}x{ca} != {wb}x{hb}x{cb}"
    if pa == pb:
        return None
    i = first_byte_diff(pa, pb)
    px = i // ca
    x, y = px % wa, px // wa
    sa, sb = tuple(pa[px * ca:px * ca + ca]), tuple(pb[px * ca:px * ca + ca])
    ndiff = sum(1 for k in range(0, len(pa), ca) if pa[k:k + ca] != pb[k:k + ca])
    return f"첫 차이 픽셀 (x={x}, y={y}): 생성 {sa} != 커밋 {sb} (다른 픽셀 {ndiff}개)"


def compare_dirs(gen_root, committed_root):
    """차이 목록 [(상대 경로, 설명)]. 비어 있으면 일치."""
    gen_root, committed_root = Path(gen_root), Path(committed_root)
    diffs = []
    ids = sorted(p.name for p in gen_root.iterdir() if p.is_dir())
    if not ids:
        return [(str(gen_root), "생성기 출력에 <id>/ 폴더가 없음")]
    for fid in ids:
        g, c = gen_root / fid, committed_root / fid
        if not c.is_dir():
            diffs.append((fid, "커밋본 폴더 없음"))
            continue
        gnames = sorted(p.name for p in g.iterdir() if p.is_file())
        cnames = sorted(p.name for p in c.iterdir() if p.is_file())
        for name in sorted(set(cnames) - set(gnames)):
            diffs.append((f"{fid}/{name}", "커밋본에만 있음(생성기가 만들지 않는 파일)"))
        for name in gnames:
            rel = f"{fid}/{name}"
            if name not in cnames:
                diffs.append((rel, "커밋본에 없음"))
            elif name.lower().endswith(".png"):
                d = compare_png(g / name, c / name)
                if d:
                    diffs.append((rel, d))
            else:
                ba, bb = (g / name).read_bytes(), (c / name).read_bytes()
                off = first_byte_diff(ba, bb)
                if off is not None:
                    diffs.append((rel, f"바이트 다름: 첫 차이 오프셋 {off} (생성 {len(ba)}B, 커밋 {len(bb)}B)"))
    return diffs


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    gen_root, committed_root = Path(argv[1]), Path(argv[2])
    for p in (gen_root, committed_root):
        if not p.is_dir():
            sys.stderr.write(f"디렉터리가 아님: {p}\n")
            return 2
    diffs = compare_dirs(gen_root, committed_root)
    ids = sorted(p.name for p in gen_root.iterdir() if p.is_dir())
    bad = {rel.split("/")[0] for rel, _ in diffs}
    for fid in ids:
        print(f"== {fid}: {'차이 있음' if fid in bad else '일치'}")
    for rel, msg in diffs:
        print(f"DIFF {rel}: {msg}")
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
