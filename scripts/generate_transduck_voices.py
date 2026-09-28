"""Extract the Azure voice catalog from the user's unpacked TransDuck extension.

Usage: python scripts/generate_transduck_voices.py PATH/TO/background.js
"""

import json
import re
import sys
from pathlib import Path


def main() -> None:
    source = Path(sys.argv[1])
    target = Path(__file__).resolve().parent.parent / "Files" / "TransDuckVoices.h"
    content = source.read_text(encoding="utf-8")
    matches = re.findall(
        r'code:"([^"]+)",language:"([^"]+)",displayName:"([^"]+)"',
        content,
    )
    voices = {code: (language, name) for code, language, name in matches}
    if len(voices) < 500 or "vi-VN-HoaiMyNeural" not in voices:
        raise ValueError("Unexpected Azure voice catalog in extension")
    ordered = sorted(
        voices.items(), key=lambda item: (item[1][0] != "vi-VN", item[1][0], item[1][1])
    )
    lines = [
        "// Generated from TransDuck 4.4.0 background.js. Do not edit by hand.",
        "static NSArray<NSDictionary *> *TDVoiceCatalog(void) {",
        "    static NSArray<NSDictionary *> *catalog;",
        "    static dispatch_once_t once;",
        "    dispatch_once(&once, ^{ catalog = @[",
    ]
    for code, (locale, name) in ordered:
        label = f"{locale} · {name}"
        lines.append(
            f"        @{{@\"id\":@{json.dumps(code, ensure_ascii=False)}, "
            f"@\"name\":@{json.dumps(label, ensure_ascii=False)}}},"
        )
    lines += ["    ]; });", "    return catalog;", "}", ""]
    target.write_text("\n".join(lines), encoding="utf-8")
    print(f"Generated {len(ordered)} Azure voices in {target}")


if __name__ == "__main__":
    main()
