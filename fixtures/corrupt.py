#!/usr/bin/env python3
"""Apply one precisely scoped corruption to a Git object, pack, or index."""

from __future__ import annotations

import os
import stat
import sys
import zlib


def rewrite_loose(path: str, operation: str) -> None:
    original_mode = stat.S_IMODE(os.stat(path).st_mode)
    with open(path, "rb") as stream:
        inflated = bytearray(zlib.decompress(stream.read()))

    header_end = inflated.find(b"\0")
    if header_end < 0:
        raise SystemExit(f"loose object has no header terminator: {path}")

    if operation == "flip-payload":
        if header_end + 1 >= len(inflated):
            raise SystemExit(f"loose object has an empty payload: {path}")
        inflated[header_end + 1] ^= 0x01
    elif operation == "malform-header":
        inflated[0] = ord("x")
    else:
        raise SystemExit(f"unknown loose-object operation: {operation}")

    os.chmod(path, original_mode | stat.S_IWUSR)
    try:
        with open(path, "wb") as stream:
            stream.write(zlib.compress(bytes(inflated), level=9))
    finally:
        os.chmod(path, original_mode)


def flip_at(path: str, offset: int) -> None:
    size = os.path.getsize(path)
    original_mode = stat.S_IMODE(os.stat(path).st_mode)
    resolved = offset if offset >= 0 else size + offset
    if resolved < 0 or resolved >= size:
        raise SystemExit(f"offset {offset} is outside {path} ({size} bytes)")

    os.chmod(path, original_mode | stat.S_IWUSR)
    try:
        with open(path, "r+b") as stream:
            stream.seek(resolved)
            original = stream.read(1)
            stream.seek(resolved)
            stream.write(bytes([original[0] ^ 0x01]))
    finally:
        os.chmod(path, original_mode)


def truncate(path: str, byte_count: int) -> None:
    size = os.path.getsize(path)
    original_mode = stat.S_IMODE(os.stat(path).st_mode)
    if byte_count <= 0 or byte_count >= size:
        raise SystemExit(f"cannot remove {byte_count} bytes from {path} ({size} bytes)")
    os.chmod(path, original_mode | stat.S_IWUSR)
    try:
        os.truncate(path, size - byte_count)
    finally:
        os.chmod(path, original_mode)


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(
            f"usage: {sys.argv[0]} (flip-payload|malform-header|flip|truncate) FILE [VALUE]"
        )

    operation, path = sys.argv[1:3]
    if operation in {"flip-payload", "malform-header"}:
        rewrite_loose(path, operation)
    elif operation == "flip" and len(sys.argv) == 4:
        flip_at(path, int(sys.argv[3]))
    elif operation == "truncate" and len(sys.argv) == 4:
        truncate(path, int(sys.argv[3]))
    else:
        raise SystemExit(f"invalid arguments for {operation}")


if __name__ == "__main__":
    main()
