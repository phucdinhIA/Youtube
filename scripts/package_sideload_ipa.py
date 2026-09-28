"""Replace the YouMod tweak in an existing sideload IPA with a CI build.

Theos may link CydiaSubstrate to its system install path. A sideloaded IPA
instead carries that framework in the app, so match the dependency used by
the working IPA before Sideloadly signs the result.
"""

import argparse
import io
import struct
import tarfile
import zipfile
from pathlib import Path


TWEAK_ENTRY = "Payload/YouTube.app/Frameworks/YouMod.dylib"
SUBSTRATE_ENTRY = "Payload/YouTube.app/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
SYSTEM_SUBSTRATE = b"/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
BUNDLED_SUBSTRATE = b"@rpath/CydiaSubstrate.framework/CydiaSubstrate"


def extract_tweak(artifact: Path) -> bytes:
    with zipfile.ZipFile(artifact) as outer:
        debs = [name for name in outer.namelist() if name.endswith(".deb")]
        if len(debs) != 1:
            raise ValueError("Expected exactly one .deb in the build artifact")
        deb = outer.read(debs[0])
    if not deb.startswith(b"!<arch>\n"):
        raise ValueError("Invalid Debian archive")
    pos = 8
    while pos < len(deb):
        header = deb[pos : pos + 60]
        if len(header) != 60 or header[58:60] != b"`\n":
            raise ValueError("Invalid Debian archive member")
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        data = deb[pos + 60 : pos + 60 + size]
        if name.startswith("data.tar"):
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
                member = archive.getmember("Library/MobileSubstrate/DynamicLibraries/YouMod.dylib")
                return archive.extractfile(member).read()
        pos += 60 + size + (size & 1)
    raise ValueError("Build artifact has no data.tar member")


def substrate_dependency(tweak: bytes) -> tuple[int, int, bytes]:
    if len(tweak) < 32 or tweak[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected an arm64 Mach-O tweak")
    count, total_size = struct.unpack_from("<II", tweak, 16)
    pos = 32
    end = pos + total_size
    if end > len(tweak):
        raise ValueError("Mach-O load commands exceed file size")
    for _ in range(count):
        if pos + 8 > end:
            raise ValueError("Truncated Mach-O load command")
        command, size = struct.unpack_from("<II", tweak, pos)
        if size < 8 or pos + size > end:
            raise ValueError("Invalid Mach-O load command size")
        if command == 0xC:  # LC_LOAD_DYLIB
            name_offset = struct.unpack_from("<I", tweak, pos + 8)[0]
            if name_offset >= size:
                raise ValueError("Invalid Mach-O dylib name offset")
            name = tweak[pos + name_offset : pos + size].split(b"\0", 1)[0]
            if b"CydiaSubstrate.framework/CydiaSubstrate" in name:
                return pos + name_offset, size - name_offset, name
        pos += size
    raise ValueError("YouMod has no CydiaSubstrate dependency")


def fix_substrate_path(tweak: bytes) -> bytes:
    offset, capacity, current = substrate_dependency(tweak)
    if current not in (SYSTEM_SUBSTRATE, BUNDLED_SUBSTRATE):
        raise ValueError(f"Unexpected CydiaSubstrate path: {current!r}")
    if len(BUNDLED_SUBSTRATE) + 1 > capacity:
        raise ValueError("No space for bundled CydiaSubstrate path")
    patched = bytearray(tweak)
    patched[offset : offset + capacity] = BUNDLED_SUBSTRATE.ljust(capacity, b"\0")
    return bytes(patched)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("working_ipa", type=Path)
    parser.add_argument("build_artifact", type=Path)
    parser.add_argument("output_ipa", type=Path)
    args = parser.parse_args()
    if args.output_ipa.exists():
        parser.error("Output IPA already exists")
    tweak = fix_substrate_path(extract_tweak(args.build_artifact))
    with zipfile.ZipFile(args.working_ipa) as source, zipfile.ZipFile(args.output_ipa, "w") as output:
        if TWEAK_ENTRY not in source.namelist() or SUBSTRATE_ENTRY not in source.namelist():
            raise ValueError("Base IPA is missing YouMod or bundled CydiaSubstrate")
        for item in source.infolist():
            output.writestr(item, tweak if item.filename == TWEAK_ENTRY else source.read(item.filename))
    with zipfile.ZipFile(args.output_ipa) as result:
        if result.testzip() is not None or result.read(TWEAK_ENTRY) != tweak:
            raise ValueError("Output IPA failed integrity check")
        if substrate_dependency(result.read(TWEAK_ENTRY))[2] != BUNDLED_SUBSTRATE:
            raise ValueError("Output IPA has the wrong CydiaSubstrate path")
    print(f"Created {args.output_ipa}")


if __name__ == "__main__":
    main()
