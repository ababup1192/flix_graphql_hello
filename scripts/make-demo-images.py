#!/usr/bin/env python3
"""import/images/*.png（取り込みのデモが使う画像）を作り直す。

役割ごとに色・寸法・文字を変えた PNG を書き出す。標準ライブラリだけで動く
（zlib で PNG を組み、5x7 のビットマップフォントで文字を打つ）。

    python3 scripts/make-demo-images.py
"""

import os
import struct
import zlib

FONT = {
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "B": ("11110", "10001", "10001", "11110", "10001", "10001", "11110"),
    "C": ("01110", "10001", "10000", "10000", "10000", "10001", "01110"),
    "D": ("11110", "10001", "10001", "10001", "10001", "10001", "11110"),
    "E": ("11111", "10000", "10000", "11110", "10000", "10000", "11111"),
    "F": ("11111", "10000", "10000", "11110", "10000", "10000", "10000"),
    "G": ("01110", "10001", "10000", "10111", "10001", "10001", "01111"),
    "H": ("10001", "10001", "10001", "11111", "10001", "10001", "10001"),
    "I": ("11111", "00100", "00100", "00100", "00100", "00100", "11111"),
    "J": ("00111", "00010", "00010", "00010", "00010", "10010", "01100"),
    "K": ("10001", "10010", "10100", "11000", "10100", "10010", "10001"),
    "L": ("10000", "10000", "10000", "10000", "10000", "10000", "11111"),
    "M": ("10001", "11011", "10101", "10101", "10001", "10001", "10001"),
    "N": ("10001", "11001", "10101", "10011", "10001", "10001", "10001"),
    "O": ("01110", "10001", "10001", "10001", "10001", "10001", "01110"),
    "P": ("11110", "10001", "10001", "11110", "10000", "10000", "10000"),
    "Q": ("01110", "10001", "10001", "10001", "10101", "10010", "01101"),
    "R": ("11110", "10001", "10001", "11110", "10100", "10010", "10001"),
    "S": ("01111", "10000", "10000", "01110", "00001", "00001", "11110"),
    "T": ("11111", "00100", "00100", "00100", "00100", "00100", "00100"),
    "U": ("10001", "10001", "10001", "10001", "10001", "10001", "01110"),
    "V": ("10001", "10001", "10001", "10001", "10001", "01010", "00100"),
    "W": ("10001", "10001", "10001", "10101", "10101", "11011", "10001"),
    "X": ("10001", "10001", "01010", "00100", "01010", "10001", "10001"),
    "Y": ("10001", "10001", "01010", "00100", "00100", "00100", "00100"),
    "Z": ("11111", "00001", "00010", "00100", "01000", "10000", "11111"),
    "0": ("01110", "10001", "10011", "10101", "11001", "10001", "01110"),
    "1": ("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
    "2": ("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
    "3": ("11111", "00010", "00100", "00010", "00001", "10001", "01110"),
    "4": ("00010", "00110", "01010", "10010", "11111", "00010", "00010"),
    "5": ("11111", "10000", "11110", "00001", "00001", "10001", "01110"),
    "6": ("00110", "01000", "10000", "11110", "10001", "10001", "01110"),
    "7": ("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
    "8": ("01110", "10001", "10001", "01110", "10001", "10001", "01110"),
    "9": ("01110", "10001", "10001", "01111", "00001", "00010", "01100"),
    "-": ("00000", "00000", "00000", "11111", "00000", "00000", "00000"),
    "/": ("00001", "00010", "00010", "00100", "01000", "01000", "10000"),
    " ": ("00000", "00000", "00000", "00000", "00000", "00000", "00000"),
}


def blank(width, height, color):
    return [[color for _ in range(width)] for _ in range(height)]


def fill_rect(pixels, x0, y0, x1, y1, color):
    for y in range(max(0, y0), min(len(pixels), y1)):
        for x in range(max(0, x0), min(len(pixels[0]), x1)):
            pixels[y][x] = color


def draw_text(pixels, text, x, y, scale, color):
    cursor = x
    for char in text.upper():
        glyph = FONT.get(char, FONT[" "])
        for row, bits in enumerate(glyph):
            for col, bit in enumerate(bits):
                if bit == "1":
                    fill_rect(
                        pixels,
                        cursor + col * scale,
                        y + row * scale,
                        cursor + (col + 1) * scale,
                        y + (row + 1) * scale,
                        color,
                    )
        cursor += 6 * scale
    return cursor


def text_width(text, scale):
    return len(text) * 6 * scale - scale


def write_png(path, pixels):
    height = len(pixels)
    width = len(pixels[0])
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for red, green, blue in row:
            raw += bytes((red, green, blue))

    def chunk(tag, payload):
        body = tag + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as out:
        out.write(png)


def make(path, width, height, background, accent, lines):
    pixels = blank(width, height, background)
    # 枠と帯で、縮小されても役割の違いが分かるようにする
    border = max(4, width // 100)
    fill_rect(pixels, 0, 0, width, border, accent)
    fill_rect(pixels, 0, height - border, width, height, accent)
    fill_rect(pixels, 0, 0, border, height, accent)
    fill_rect(pixels, width - border, 0, width, height, accent)

    longest = max(len(line) for line in lines)
    scale = max(2, min((width * 8 // 10) // (6 * longest), (height * 7 // 10) // (10 * len(lines))))
    block = len(lines) * 10 * scale
    top = (height - block) // 2
    for index, line in enumerate(lines):
        left = (width - text_width(line, scale)) // 2
        draw_text(pixels, line, left, top + index * 10 * scale, scale, accent)
    write_png(path, pixels)
    return os.path.getsize(path)


def main():
    out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "import", "images")
    os.makedirs(out_dir, exist_ok=True)
    specs = [
        ("demo-wide.png", 1200, 630, (18, 32, 62), (120, 190, 255), ["image 1", "wide", "in body"]),
        ("demo-side-a.png", 800, 600, (20, 56, 40), (130, 235, 170), ["image 2", "side a", "left"]),
        ("demo-side-b.png", 800, 600, (66, 38, 12), (255, 190, 110), ["image 3", "side b", "right"]),
        ("demo-tall.png", 600, 900, (48, 22, 62), (215, 160, 255), ["image 4", "tall", "size align"]),
    ]
    for name, width, height, background, accent, lines in specs:
        size = make(os.path.join(out_dir, name), width, height, background, accent, lines)
        print(f"{name}: {width}x{height} {size} bytes")


if __name__ == "__main__":
    main()
