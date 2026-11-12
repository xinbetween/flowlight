#!/usr/bin/env python3
"""Validate Flowlight's executable light/dark chart palette from DesignTokens.swift."""

from __future__ import annotations

import argparse
import itertools
import math
import pathlib
import re
import sys

TOKEN_PATTERN = re.compile(
    r"static\s+let\s+(\w+)\s*=\s*Color\(light:\s*0x([0-9a-fA-F]{6}),\s*dark:\s*0x([0-9a-fA-F]{6})\)"
)
REQUIRED = {
    "ground", "surface", "ink", "muted", "received", "sent",
    "graphReceived", "graphSent", "graphInvocation",
}
MACHADO = {
    "protan": (
        (0.152286, 1.052583, -0.204868),
        (0.114503, 0.786281, 0.099216),
        (-0.003882, -0.048116, 1.051998),
    ),
    "deutan": (
        (0.367322, 0.860646, -0.227968),
        (0.280085, 0.672501, 0.047413),
        (-0.011820, 0.042940, 0.968881),
    ),
}


def parse_tokens(source: str) -> dict[str, dict[str, str]]:
    return {
        name: {"light": light.lower(), "dark": dark.lower()}
        for name, light, dark in TOKEN_PATTERN.findall(source)
    }


def srgb_channel(value: int) -> float:
    channel = value / 255.0
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def linear_rgb(value: str) -> tuple[float, float, float]:
    return tuple(srgb_channel(int(value[index:index + 2], 16)) for index in (0, 2, 4))


def oklab(rgb: tuple[float, float, float]) -> tuple[float, float, float]:
    red, green, blue = rgb
    l_value = 0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue
    m_value = 0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue
    s_value = 0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue
    l_root = math.copysign(abs(l_value) ** (1 / 3), l_value)
    m_root = math.copysign(abs(m_value) ** (1 / 3), m_value)
    s_root = math.copysign(abs(s_value) ** (1 / 3), s_value)
    return (
        0.2104542553 * l_root + 0.7936177850 * m_root - 0.0040720468 * s_root,
        1.9779984951 * l_root - 2.4285922050 * m_root + 0.4505937099 * s_root,
        0.0259040371 * l_root + 0.7827717662 * m_root - 0.8086757660 * s_root,
    )


def simulate(rgb: tuple[float, float, float], matrix: tuple[tuple[float, ...], ...]) -> tuple[float, float, float]:
    return tuple(max(0.0, min(1.0, sum(row[index] * rgb[index] for index in range(3)))) for row in matrix)


def delta(left: tuple[float, float, float], right: tuple[float, float, float]) -> float:
    return math.sqrt(sum((left[index] - right[index]) ** 2 for index in range(3))) * 100


def contrast(left: tuple[float, float, float], right: tuple[float, float, float]) -> float:
    def luminance(rgb: tuple[float, float, float]) -> float:
        return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]

    light, dark = sorted((luminance(left), luminance(right)), reverse=True)
    return (light + 0.05) / (dark + 0.05)


def validate(tokens: dict[str, dict[str, str]]) -> list[str]:
    missing = sorted(REQUIRED - tokens.keys())
    if missing:
        return [f"missing semantic token: {name}" for name in missing]

    issues: list[str] = []
    palettes = {
        "directional": ("received", "sent"),
        "graph": ("graphReceived", "graphSent", "graphInvocation"),
    }
    for mode in ("light", "dark"):
        surface = linear_rgb(tokens["surface"][mode])
        band = (0.43, 0.77) if mode == "light" else (0.48, 0.67)
        for palette_name, names in palettes.items():
            values = {name: linear_rgb(tokens[name][mode]) for name in names}
            for name, rgb in values.items():
                lightness, a_value, b_value = oklab(rgb)
                chroma = math.sqrt(a_value * a_value + b_value * b_value)
                if not band[0] <= lightness <= band[1]:
                    issues.append(f"{mode} {name} lightness {lightness:.3f} outside {band[0]:.2f}-{band[1]:.2f}")
                if chroma < 0.10:
                    issues.append(f"{mode} {name} chroma {chroma:.3f} below 0.10")
                mark_contrast = contrast(rgb, surface)
                if mark_contrast < 3.0:
                    issues.append(f"{mode} {name} contrast {mark_contrast:.2f}:1 below 3:1")

            for left_name, right_name in itertools.combinations(names, 2):
                left, right = values[left_name], values[right_name]
                normal = delta(oklab(left), oklab(right))
                if normal < 15:
                    issues.append(f"{mode} {palette_name} {left_name}/{right_name} normal Delta E {normal:.1f} below 15")
                for simulation, matrix in MACHADO.items():
                    separation = delta(oklab(simulate(left, matrix)), oklab(simulate(right, matrix)))
                    if separation < 8:
                        issues.append(
                            f"{mode} {palette_name} {left_name}/{right_name} {simulation} Delta E {separation:.1f} below 8"
                        )

        for text_name in ("ink", "muted"):
            for surface_name in ("ground", "surface"):
                ratio = contrast(linear_rgb(tokens[text_name][mode]), linear_rgb(tokens[surface_name][mode]))
                if ratio < 4.5:
                    issues.append(f"{mode} {text_name} on {surface_name} contrast {ratio:.2f}:1 below 4.5:1")
    return issues


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1] / "Flowlight/UI/DesignTokens.swift",
    )
    args = parser.parse_args()
    tokens = parse_tokens(args.source.read_text(encoding="utf-8"))
    issues = validate(tokens)
    if issues:
        for issue in issues:
            print(f"palette rejected: {issue}", file=sys.stderr)
        return 1
    print("Flowlight chart palette passes light/dark contrast, chroma, normal-vision, protan, and deutan checks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
