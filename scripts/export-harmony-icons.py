#!/usr/bin/env python3
"""导出 Org Tasks 的 HarmonyOS App 图标资源。

默认把两套 SVG 图标导出到 AppScope 的 media 目录，并生成
256/512/1024 三种尺寸。HarmonyOS 使用 app_icon.png；备用方案保留为
app_icon_outline.png，便于在设计评审或后续切换时直接使用。
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE_DIR = ROOT / "design" / "icons"
DEFAULT_OUTPUTS = (
    ROOT / "AppScope" / "resources" / "base" / "media",
)
SIZES = (256, 512, 1024)
ICONS = {
    "check": ("org_tasks_check.svg", "app_icon.png"),
    "outline": ("org_tasks_outline.svg", "app_icon_outline.png"),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="导出 HarmonyOS App 图标 PNG 资源")
    parser.add_argument(
        "--icon",
        choices=("check", "outline", "both"),
        default="both",
        help="导出的方案；默认导出主方案和备用方案",
    )
    parser.add_argument(
        "--size",
        type=int,
        nargs="+",
        default=list(SIZES),
        help="输出尺寸（像素），默认：256 512 1024",
    )
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=DEFAULT_SOURCE_DIR,
        help="SVG 源文件目录",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        action="append",
        dest="output_dirs",
        help="PNG 输出目录；可重复指定，默认写入 AppScope",
    )
    return parser.parse_args()


def convert(svg: Path, png: Path, size: int) -> None:
    converter = shutil.which("rsvg-convert") or shutil.which("magick")
    if converter is None:
        raise RuntimeError("未找到 rsvg-convert 或 magick，请安装 librsvg 或 ImageMagick")
    png.parent.mkdir(parents=True, exist_ok=True)
    if Path(converter).name == "rsvg-convert":
        command = [converter, "-w", str(size), "-h", str(size), "-o", str(png), str(svg)]
    else:
        command = [converter, "-background", "none", str(svg), "-resize", f"{size}x{size}", str(png)]
    subprocess.run(command, check=True)


def main() -> int:
    args = parse_args()
    output_dirs = tuple(args.output_dirs or DEFAULT_OUTPUTS)
    icon_names = tuple(ICONS) if args.icon == "both" else (args.icon,)
    sizes = tuple(dict.fromkeys(args.size))
    if any(size <= 0 for size in sizes):
        print("尺寸必须是正整数", file=sys.stderr)
        return 2

    for icon_name in icon_names:
        source_name, base_name = ICONS[icon_name]
        source = args.source_dir / source_name
        if not source.is_file():
            print(f"找不到 SVG 源文件：{source}", file=sys.stderr)
            return 2
        for output_dir in output_dirs:
            for size in sizes:
                suffix = f"_{size}" if size != 256 else ""
                filename = f"{Path(base_name).stem}{suffix}.png"
                destination = output_dir / filename
                convert(source, destination, size)
                try:
                    display_path = destination.relative_to(ROOT)
                except ValueError:
                    display_path = destination
                print(display_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
