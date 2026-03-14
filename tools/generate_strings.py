#!/usr/bin/env python3
import json
import pathlib
import sys

ZIG_KEYWORDS = {
    "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await",
    "break", "callconv", "catch", "comptime", "const", "continue", "defer", "else",
    "enum", "errdefer", "error", "export", "extern", "false", "fn", "for", "if",
    "inline", "linksection", "noalias", "noinline", "nosuspend", "null", "opaque",
    "or", "orelse", "packed", "pub", "resume", "return", "struct", "suspend",
    "switch", "test", "threadlocal", "true", "try", "union", "unreachable", "usingnamespace",
    "var", "volatile", "while",
}


def zig_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def zig_ident(name: str) -> str:
    return f'@"{name}"' if name in ZIG_KEYWORDS else name


def emit_value(name: str, value, indent: int) -> list[str]:
    pad = " " * indent
    ident = zig_ident(name)
    if isinstance(value, str):
        return [f"{pad}pub const {ident} = {zig_string(value)};"]
    if isinstance(value, list):
        lines = [f"{pad}pub const {ident} = [_][]const u8{{"]
        for item in value:
            if not isinstance(item, str):
                raise TypeError(f"array value for {name} must be string")
            lines.append(f"{pad}    {zig_string(item)},")
        lines.append(f"{pad}}};")
        return lines
    if isinstance(value, dict):
        lines = [f"{pad}pub const {ident} = struct {{"]
        for child_name in sorted(value):
            lines.extend(emit_value(child_name, value[child_name], indent + 4))
        lines.append(f"{pad}}};")
        return lines
    raise TypeError(f"unsupported value for {name}: {type(value).__name__}")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: generate_strings.py <input.json> <output.zig>", file=sys.stderr)
        return 1

    input_path = pathlib.Path(sys.argv[1])
    output_path = pathlib.Path(sys.argv[2])
    data = json.loads(input_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TypeError("top-level JSON must be an object")

    lines = [
        "// Generated from ui_strings.json. Do not edit by hand.",
        "",
        "pub const Strings = struct {",
    ]
    for name in sorted(data):
        lines.extend(emit_value(name, data[name], 4))
    lines.extend([
        "};",
        "",
        "pub const strings = Strings{};",
        "",
    ])

    output_path.write_text("\n".join(lines), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
