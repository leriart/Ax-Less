#!/usr/bin/env python3
"""
Wallpaper palette extractor for NothingLess.

Extracts dominant colors from a wallpaper and writes a full M3 palette to
~/.cache/nothingless/colors.json. Designed to be a higher-fidelity alternative
to `matugen` when the user wants the actual wallpaper colors instead of a
muted single-source HCT derivative.

Modes:
  multi-dominant  Top 3 most frequent colors → primary/secondary/tertiary.
  contrast        Top 3 colors that stand out most from the other extracted
                  colors (perceptual distance against the rest).
  vibrant         Top 3 most saturated colors.

The extracted primary/secondary/tertiary are used as-is for their respective
roles (no hue rotation, no desaturation). The M3 surface hierarchy, on-colors,
containers, fixed variants, and accent palette (red/green/blue/yellow/cyan/
magenta/white) are derived deterministically from the 3 source colors so the
final palette stays internally consistent with the wallpaper.
"""

import json
import math
import os
import sys
from collections import Counter

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow is required. Install with: pip install pillow",
          file=sys.stderr)
    sys.exit(1)


CACHE_PATH = os.path.expanduser("~/.cache/nothingless/colors.json")

VALID_MODES = ("multi-dominant", "contrast", "vibrant")


# ---------------------------------------------------------------------------
# Color space helpers
# ---------------------------------------------------------------------------

def rgb_to_hls(r, g, b):
    """RGB (0-255) → HLS (h in 0-1, l in 0-1, s in 0-1)."""
    import colorsys
    return colorsys.rgb_to_hls(r / 255.0, g / 255.0, b / 255.0)


def hls_to_hex(h, l, s):
    """HLS (0-1) → '#RRGGBB'."""
    import colorsys
    h = h % 1.0
    l = max(0.0, min(1.0, l))
    s = max(0.0, min(1.0, s))
    r, g, b = colorsys.hls_to_rgb(h, l, s)
    return "#{:02X}{:02X}{:02X}".format(
        int(round(r * 255)), int(round(g * 255)), int(round(b * 255)))


def luminance(r, g, b):
    """Relative luminance per WCAG (0-1)."""
    def channel(c):
        c = c / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def contrast_ratio(c1, c2):
    """WCAG contrast ratio between two RGB triples."""
    l1 = luminance(*c1)
    l2 = luminance(*c2)
    lighter = max(l1, l2)
    darker = min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)


# ---------------------------------------------------------------------------
# Dominant color extraction (Pillow median cut)
# ---------------------------------------------------------------------------

def extract_dominant_colors(image_path, count=12):
    """Quantize the image to N colors and return them sorted by frequency.

    Each entry has r/g/b (0-255), h/l/s (0-1) and frequency (0-1)."""
    img = Image.open(image_path).convert("RGB")
    img.thumbnail((200, 200))

    # method=2 → MEDIANCUT, good balance of speed and quality.
    quantized = img.quantize(colors=count, method=2, kmeans=3)
    palette = quantized.getpalette()[:count * 3]

    pixel_data = quantized.get_flattened_data() if hasattr(
        quantized, "get_flattened_data") else quantized.getdata()
    counts = Counter(pixel_data)
    total = sum(counts.values()) or 1

    colors = []
    for idx, freq in counts.most_common():
        r, g, b = palette[idx * 3:idx * 3 + 3]
        h, l, s = rgb_to_hls(r, g, b)
        colors.append({
            "r": r, "g": g, "b": b,
            "h": h, "l": l, "s": s,
            "frequency": freq / total,
        })

    return colors


# ---------------------------------------------------------------------------
# Selection strategies
# ---------------------------------------------------------------------------

def score_contrast(color, others):
    """Average WCAG contrast ratio against the other colors.

    Higher = stands out more."""
    if not others:
        return 0.0
    ratios = [contrast_ratio((color["r"], color["g"], color["b"]),
                             (o["r"], o["g"], o["b"]))
              for o in others if o is not color]
    return sum(ratios) / len(ratios) if ratios else 0.0


def score_vibrancy(color):
    """Combined chroma + saturation, weighted toward the latter."""
    # HLS s is already a reasonable proxy for vibrancy; bump underused ranges.
    return color["s"]


def select_colors(colors, mode, count=3):
    """Pick the top `count` colors according to the chosen mode."""
    if mode == "multi-dominant":
        return colors[:count]
    if mode == "contrast":
        scored = [(score_contrast(c, colors), i, c)
                  for i, c in enumerate(colors)]
        scored.sort(reverse=True)
        return [c for _, _, c in scored[:count]]
    if mode == "vibrant":
        scored = [(score_vibrancy(c), i, c)
                  for i, c in enumerate(colors)]
        scored.sort(reverse=True)
        return [c for _, _, c in scored[:count]]
    return colors[:count]


# ---------------------------------------------------------------------------
# M3 palette generation
# ---------------------------------------------------------------------------

def _hex(rgb):
    return "#{:02X}{:02X}{:02X}".format(int(rgb[0]), int(rgb[1]), int(rgb[2]))


def _shift_hue(h, delta):
    return h + delta


def _l_for_mode(light_mode, dark_l, light_l):
    return light_l if light_mode else dark_l


def generate_palette(primary, secondary, tertiary, light_mode=False,
                     source_color=None):
    """Build the full M3 palette object from the three source colors.

    Primary/secondary/tertiary are used at their extracted saturation and
    hue — only the lightness is shifted to the M3 tone for the role. The
    surface hierarchy is darkened/lightened around the primary hue so the
    shell still feels coherent with the wallpaper."""
    p_h, p_s = primary["h"], primary["s"]
    s_h, s_s = secondary["h"], secondary["s"]
    t_h, t_s = tertiary["h"], tertiary["s"]

    avg_l = (primary["l"] + secondary["l"] + tertiary["l"]) / 3.0
    if source_color is None:
        source_color = (primary["r"], primary["g"], primary["b"])

    # Tone targets per M3 spec
    p_tone = _l_for_mode(light_mode, 0.80, 0.40)
    p_container_tone = _l_for_mode(light_mode, 0.30, 0.90)
    p_fixed_tone = _l_for_mode(light_mode, 0.90, 0.90)
    p_fixed_dim_tone = _l_for_mode(light_mode, 0.80, 0.80)

    s_tone = _l_for_mode(light_mode, 0.80, 0.40)
    s_container_tone = _l_for_mode(light_mode, 0.30, 0.90)

    t_tone = _l_for_mode(light_mode, 0.80, 0.40)
    t_container_tone = _l_for_mode(light_mode, 0.30, 0.90)

    # On-* contrast colors
    on_p = _l_for_mode(light_mode, 0.10, 0.98)
    on_container = _l_for_mode(light_mode, 0.10, 0.98)
    on_fixed = _l_for_mode(light_mode, 0.10, 0.10)

    # Surface hierarchy (M3 dark/light)
    surface_l = _l_for_mode(light_mode, 0.10, 0.96)
    surface_dim_l = _l_for_mode(light_mode, 0.06, 0.92)
    surface_bright_l = _l_for_mode(light_mode, 0.25, 0.98)
    c_lowest_l = _l_for_mode(light_mode, 0.04, 1.00)
    c_low_l = _l_for_mode(light_mode, 0.08, 0.96)
    c_mid_l = _l_for_mode(light_mode, 0.12, 0.94)
    c_high_l = _l_for_mode(light_mode, 0.17, 0.92)
    c_highest_l = _l_for_mode(light_mode, 0.22, 0.90)
    on_surface_l = _l_for_mode(light_mode, 0.92, 0.10)
    on_surface_var_l = _l_for_mode(light_mode, 0.75, 0.30)
    outline_l = _l_for_mode(light_mode, 0.55, 0.50)
    outline_var_l = _l_for_mode(light_mode, 0.30, 0.80)

    p = {}

    # --- source + tint ---
    p["sourceColor"] = _hex(source_color)
    p["surfaceTint"] = hls_to_hex(p_h, p_tone, min(1.0, p_s))

    # --- primary ---
    p["primary"] = hls_to_hex(p_h, p_tone, min(1.0, p_s))
    p["primaryContainer"] = hls_to_hex(p_h, p_container_tone,
                                        min(1.0, p_s * 0.6))
    p["onPrimary"] = hls_to_hex(p_h, on_p, 0.0)
    p["onPrimaryContainer"] = hls_to_hex(p_h, on_container, 0.0)
    p["primaryFixed"] = hls_to_hex(p_h, p_fixed_tone, min(1.0, p_s))
    p["primaryFixedDim"] = hls_to_hex(p_h, p_fixed_dim_tone, min(1.0, p_s))
    p["onPrimaryFixed"] = hls_to_hex(p_h, on_fixed, 0.0)
    p["onPrimaryFixedVariant"] = hls_to_hex(p_h, on_fixed, 0.0)
    p["inversePrimary"] = hls_to_hex(p_h, _l_for_mode(light_mode, 0.40, 0.80),
                                      min(1.0, p_s))

    # --- secondary ---
    p["secondary"] = hls_to_hex(s_h, s_tone, min(1.0, s_s))
    p["secondaryContainer"] = hls_to_hex(s_h, s_container_tone,
                                          min(1.0, s_s * 0.6))
    p["onSecondary"] = hls_to_hex(s_h, on_p, 0.0)
    p["onSecondaryContainer"] = hls_to_hex(s_h, on_container, 0.0)
    p["secondaryFixed"] = hls_to_hex(s_h, p_fixed_tone, min(1.0, s_s))
    p["secondaryFixedDim"] = hls_to_hex(s_h, p_fixed_dim_tone, min(1.0, s_s))
    p["onSecondaryFixed"] = hls_to_hex(s_h, on_fixed, 0.0)
    p["onSecondaryFixedVariant"] = hls_to_hex(s_h, on_fixed, 0.0)

    # --- tertiary ---
    p["tertiary"] = hls_to_hex(t_h, t_tone, min(1.0, t_s))
    p["tertiaryContainer"] = hls_to_hex(t_h, t_container_tone,
                                         min(1.0, t_s * 0.6))
    p["onTertiary"] = hls_to_hex(t_h, on_p, 0.0)
    p["onTertiaryContainer"] = hls_to_hex(t_h, on_container, 0.0)
    p["tertiaryFixed"] = hls_to_hex(t_h, p_fixed_tone, min(1.0, t_s))
    p["tertiaryFixedDim"] = hls_to_hex(t_h, p_fixed_dim_tone, min(1.0, t_s))
    p["onTertiaryFixed"] = hls_to_hex(t_h, on_fixed, 0.0)
    p["onTertiaryFixedVariant"] = hls_to_hex(t_h, on_fixed, 0.0)

    # --- error (fixed Material baseline, mode-aware) ---
    if light_mode:
        p["error"] = "#BA1A1A"
        p["errorContainer"] = "#FFDAD6"
        p["onError"] = "#FFFFFF"
        p["onErrorContainer"] = "#410002"
    else:
        p["error"] = "#FFB4AB"
        p["errorContainer"] = "#93000A"
        p["onError"] = "#690005"
        p["onErrorContainer"] = "#FFDAD6"

    # --- surfaces ---
    p["background"] = hls_to_hex(p_h, surface_dim_l, 0.02)
    p["surface"] = hls_to_hex(p_h, surface_l, 0.02)
    p["surfaceDim"] = hls_to_hex(p_h, surface_dim_l, 0.02)
    p["surfaceBright"] = hls_to_hex(p_h, surface_bright_l, 0.04)
    p["surfaceContainerLowest"] = hls_to_hex(p_h, c_lowest_l, 0.02)
    p["surfaceContainerLow"] = hls_to_hex(p_h, c_low_l, 0.02)
    p["surfaceContainer"] = hls_to_hex(p_h, c_mid_l, 0.03)
    p["surfaceContainerHigh"] = hls_to_hex(p_h, c_high_l, 0.04)
    p["surfaceContainerHighest"] = hls_to_hex(p_h, c_highest_l, 0.05)
    p["surfaceVariant"] = hls_to_hex(p_h, c_mid_l, 0.04)
    p["onBackground"] = hls_to_hex(p_h, on_surface_l, 0.02)
    p["onSurface"] = hls_to_hex(p_h, on_surface_l, 0.02)
    p["onSurfaceVariant"] = hls_to_hex(p_h, on_surface_var_l, 0.03)
    p["outline"] = hls_to_hex(p_h, outline_l, 0.04)
    p["outlineVariant"] = hls_to_hex(p_h, outline_var_l, 0.03)
    p["inverseSurface"] = hls_to_hex(p_h, on_surface_l, 0.02)
    p["inverseOnSurface"] = hls_to_hex(p_h, surface_l, 0.02)
    p["scrim"] = "#000000"
    p["shadow"] = "#000000"

    # --- accent palette ---
    # Each accent uses one of the 3 source colors as its source hex and is
    # projected through the M3 tones for consistency with primary/secondary/
    # tertiary. lightXxx is a +10% lightness shift for variant UIs.
    def accent_block(name, color, light_name=None):
        ch, cs, cl = color["h"], color["s"], color["l"]
        src = _hex((color["r"], color["g"], color["b"]))
        p[name] = hls_to_hex(ch, p_tone, min(1.0, cs))
        p[name + "Container"] = hls_to_hex(ch, p_container_tone,
                                            min(1.0, cs * 0.6))
        p["on" + name[0].upper() + name[1:]] = hls_to_hex(ch, on_p, 0.0)
        p["on" + name[0].upper() + name[1:] + "Container"] = hls_to_hex(
            ch, on_container, 0.0)
        if light_name:
            p[light_name] = hls_to_hex(
                ch, min(0.95, cl + 0.1), min(1.0, cs))
        p[name + "Source"] = src
        p[name + "Value"] = src

    accent_block("red", primary, "lightRed")
    accent_block("green", secondary, "lightGreen")
    accent_block("blue", tertiary, "lightBlue")

    # Synthesize yellow/cyan/magenta as hue-shifted siblings of the 3 sources
    # so the palette stays internally consistent with the wallpaper.
    accent_block("yellow",
                 {"r": 0, "g": 0, "b": 0,
                  "h": _shift_hue(p_h, 0.14), "s": p_s, "l": primary["l"]},
                 "lightYellow")
    accent_block("cyan",
                 {"r": 0, "g": 0, "b": 0,
                  "h": _shift_hue(s_h, 0.5), "s": s_s, "l": secondary["l"]},
                 "lightCyan")
    accent_block("magenta",
                 {"r": 0, "g": 0, "b": 0,
                  "h": _shift_hue(t_h, -0.5), "s": t_s, "l": tertiary["l"]},
                 "lightMagenta")

    # White/black accents
    p["white"] = hls_to_hex(p_h, min(0.95, primary["l"] + 0.2),
                             min(0.25, p_s * 0.3))
    p["whiteContainer"] = hls_to_hex(p_h,
                                      min(0.9, primary["l"] + 0.15),
                                      min(0.2, p_s * 0.2))
    p["onWhite"] = hls_to_hex(p_h, 0.10, 0.0)
    p["onWhiteContainer"] = hls_to_hex(p_h, 0.20, 0.0)
    p["whiteSource"] = "#FFFFFF"
    p["whiteValue"] = "#FFFFFF"

    return p


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 3 or sys.argv[1] in ("-h", "--help"):
        print("Usage: extract_palette.py <wallpaper> <mode> "
              "[--light] [--output PATH]", file=sys.stderr)
        print("Modes: " + ", ".join(VALID_MODES), file=sys.stderr)
        sys.exit(1)

    wallpaper = sys.argv[1]
    mode = sys.argv[2]
    light_mode = "--light" in sys.argv

    output = CACHE_PATH
    if "--output" in sys.argv:
        idx = sys.argv.index("--output")
        output = sys.argv[idx + 1]

    if mode not in VALID_MODES:
        print(f"ERROR: invalid mode '{mode}'. Valid: "
              + ", ".join(VALID_MODES), file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(wallpaper):
        print(f"ERROR: wallpaper not found: {wallpaper}", file=sys.stderr)
        sys.exit(1)

    try:
        colors = extract_dominant_colors(wallpaper, count=12)
    except Exception as e:
        print(f"ERROR: failed to extract colors from {wallpaper}: {e}",
              file=sys.stderr)
        sys.exit(1)

    selected = select_colors(colors, mode, count=3)
    while len(selected) < 3:
        selected.append(selected[0] if selected else
                        {"r": 128, "g": 128, "b": 128,
                         "h": 0.0, "l": 0.5, "s": 0.0, "frequency": 1.0})

    primary, secondary, tertiary = selected
    palette = generate_palette(primary, secondary, tertiary,
                                light_mode=light_mode)

    try:
        with open(output, "w") as f:
            json.dump(palette, f, indent=2)
    except OSError as e:
        print(f"ERROR: failed to write {output}: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"✅ Extracted [{mode}] palette → {output}", file=sys.stderr)
    print(f"   primary   = {palette['primary']:<8}  "
          f"(source {palette['redSource']})", file=sys.stderr)
    print(f"   secondary = {palette['secondary']:<8}  "
          f"(source {palette['greenSource']})", file=sys.stderr)
    print(f"   tertiary  = {palette['tertiary']:<8}  "
          f"(source {palette['blueSource']})", file=sys.stderr)


if __name__ == "__main__":
    main()
