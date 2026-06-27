#!/usr/bin/env python3
"""Repoint Highlightr's Bundle.module fallback path inside a built CmdMD binary.

The SwiftPM-generated accessor resolves the resource bundle as:

    Bundle(path: Bundle.main.bundleURL + "Highlightr_Highlightr.bundle")   # = .app ROOT (unsignable)
      ?? Bundle(path: "<...>/.build/<arch>/release/Highlightr_Highlightr.bundle")  # = CI path (absent for users)

In a packaged .app both candidates fail, so Highlightr.init() hits fatalError the moment the
editor renders. This patches the second (baked) string to the bundle that package_app.sh ships in
Contents/Resources, so the fallback resolves at runtime.

It is an in-place, equal-length, NUL-padded replacement, so all Mach-O offsets are preserved.
Run it BEFORE codesign; the subsequent `codesign --force --deep --sign -` re-seals the binary.

usage: fix-highlightr-bundle.py <path/to/CmdMD.app/Contents/MacOS/CmdMD>

NOTE: the replacement path assumes the documented /Applications install location. For full
install-location independence, build the .app with an Xcode/xcodebuild app target instead (its
resource accessor checks Bundle.main.resourceURL, i.e. Contents/Resources).
"""
import sys

NEW = b"/Applications/CmdMD.app/Contents/Resources/Highlightr_Highlightr.bundle"
NEEDLE = b"Highlightr_Highlightr.bundle"


def find_buildpath(data: bytearray):
    """Return (start, end) of the baked '<...>/.build/.../Highlightr_Highlightr.bundle' C string."""
    pos = 0
    while True:
        i = data.find(NEEDLE, pos)
        if i == -1:
            return None
        start = data.rfind(b"\x00", 0, i) + 1          # C string begins after the previous NUL
        end = data.find(b"\x00", i)
        cstr = bytes(data[start:end])
        # the build-path literal contains ".build/"; the bare-name literal used by mainPath does not
        if b"/.build/" in cstr and cstr.endswith(NEEDLE):
            return start, end
        pos = i + len(NEEDLE)


def main(bin_path: str) -> None:
    data = bytearray(open(bin_path, "rb").read())
    hit = find_buildpath(data)
    if hit is None:
        sys.exit("buildPath string not found (already patched or unexpected build layout)")
    start, end = hit
    old_len = end - start
    if len(NEW) > old_len:
        sys.exit(f"replacement path ({len(NEW)}B) longer than original ({old_len}B); cannot patch in place")
    data[start:end] = NEW + b"\x00" * (old_len - len(NEW))
    open(bin_path, "wb").write(data)
    print(f"patched buildPath @ offset {start} -> {NEW.decode()}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
