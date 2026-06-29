#!/usr/bin/env python3
"""
bin2mem32.py — 把二进制文件转成每行一个 32-bit hex word 的 .mem 文件。

用途：
  生成的 .mem 文件可用 Verilog $readmemh 直接加载到 simple_rom / simple_ram。

用法：
  ./scripts/bin2mem32.py input.bin output.mem

流程：
  1. 读入整个 binary
  2. 末尾补零到 4 字节对齐
  3. 按小端序逐字输出 hex（每行一个 32-bit word）

示例：
  # 将 smoke.bin 转成 smoke.mem
  ./scripts/bin2mem32.py build/smoke.bin build/smoke.mem

  # simple_rom 加载
  # $readmemh("smoke.mem", mem_array);
"""

import sys
import os


def main():
    if len(sys.argv) == 2 and sys.argv[1] in ("-h", "--help"):
        print(f"用法: {os.path.basename(sys.argv[0])} <input.bin> <output.mem>")
        sys.exit(0)

    if len(sys.argv) != 3:
        print(f"用法: {os.path.basename(sys.argv[0])} <input.bin> <output.mem>", file=sys.stderr)
        sys.exit(1)

    in_path = sys.argv[1]
    out_path = sys.argv[2]

    # 读入二进制文件
    with open(in_path, "rb") as f:
        data = f.read()

    # 补零到 4 字节对齐
    pad = (4 - len(data) % 4) % 4
    data += b"\x00" * pad

    # 按小端序逐字写入 .mem 文件
    with open(out_path, "w") as f:
        for i in range(0, len(data), 4):
            word = data[i] | (data[i+1] << 8) | (data[i+2] << 16) | (data[i+3] << 24)
            f.write(f"{word:08x}\n")

    print(f"OK: {len(data)//4} words ({len(data)} bytes) written to {out_path}")


if __name__ == "__main__":
    main()
