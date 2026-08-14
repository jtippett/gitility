#!/usr/bin/env python3
"""Write a stable, byte-oriented inventory for the generated fixture tree."""

from __future__ import annotations

import base64
import hashlib
import os
import stat
import sys


def encoded(path: bytes) -> str:
    return base64.b64encode(path).decode("ascii")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} DIRECTORY")

    root = os.fsencode(os.path.abspath(sys.argv[1]))
    entries: list[tuple[bytes, bytes]] = []

    for current, directories, files in os.walk(root):
        directories.sort()
        files.sort()

        for name in directories + files:
            full_path = os.path.join(current, name)
            relative_path = os.path.relpath(full_path, root)
            if relative_path == b"CHECKSUMS":
                continue
            metadata = os.lstat(full_path)
            mode = stat.S_IMODE(metadata.st_mode)

            if stat.S_ISDIR(metadata.st_mode):
                kind = b"directory"
                digest = hashlib.sha256(b"").hexdigest().encode("ascii")
            elif stat.S_ISLNK(metadata.st_mode):
                kind = b"symlink"
                digest = hashlib.sha256(os.readlink(full_path)).hexdigest().encode(
                    "ascii"
                )
            elif stat.S_ISREG(metadata.st_mode):
                kind = b"file"
                hasher = hashlib.sha256()
                with open(full_path, "rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        hasher.update(chunk)
                digest = hasher.hexdigest().encode("ascii")
            else:
                raise SystemExit(f"unsupported filesystem entry: {full_path!r}")

            line = b" ".join(
                [kind, f"{mode:04o}".encode("ascii"), digest, encoded(relative_path).encode("ascii")]
            )
            entries.append((relative_path, line))

    for _path, line in sorted(entries, key=lambda item: item[0]):
        print(line.decode("ascii"))


if __name__ == "__main__":
    main()
