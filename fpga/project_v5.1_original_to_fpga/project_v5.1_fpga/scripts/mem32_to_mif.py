#!/usr/bin/env python3
"""Convert one-word-per-line 32-bit hex .mem into a Quartus .mif file."""

import argparse


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("input_mem")
    parser.add_argument("output_mif")
    parser.add_argument("--depth", type=int, default=4096)
    parser.add_argument("--width", type=int, default=32)
    return parser.parse_args()


def main():
    args = parse_args()
    words = []

    with open(args.input_mem, "r", encoding="ascii") as f:
        for line in f:
            text = line.split("//", 1)[0].strip()
            if text:
                words.append(int(text, 16) & ((1 << args.width) - 1))

    if len(words) > args.depth:
        raise SystemExit(f"ERROR: {args.input_mem} has {len(words)} words, depth is {args.depth}")

    with open(args.output_mif, "w", encoding="ascii", newline="\n") as f:
        f.write(f"WIDTH={args.width};\n")
        f.write(f"DEPTH={args.depth};\n\n")
        f.write("ADDRESS_RADIX=HEX;\n")
        f.write("DATA_RADIX=HEX;\n\n")
        f.write("CONTENT BEGIN\n")
        for addr, word in enumerate(words):
            f.write(f"    {addr:03X} : {word:08X};\n")
        if len(words) < args.depth:
            f.write(f"    [{len(words):03X}..{args.depth - 1:03X}] : 00000000;\n")
        f.write("END;\n")


if __name__ == "__main__":
    main()
