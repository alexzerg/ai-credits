#!/usr/bin/env python3
import json, os, sys, base64
from PIL import Image, ImageDraw, ImageFont

CACHE_DIR = os.path.expanduser(os.environ.get("AI_CREDITS_CACHE_DIR") or os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "ai-credits"))
ICON_DIR = os.path.join(CACHE_DIR, "icons")
SUMMARY = os.path.join(CACHE_DIR, "summary.json")

def pct_of(name):
    try:
        with open(SUMMARY) as f:
            d = json.load(f)
        for s in d.get("services", []):
            k = s.get("key","")
            if k == name or (name == "dust" and k == "dust") or (name == "muse" and k == "muse") or (name == "claude" and k == "claude"):
                p = s.get("pct")
                if p is None or p == "—": return "—"
                if isinstance(p, (int,float)): return f"{int(round(p))}%"
                return str(p)
    except Exception:
        pass
    return "—"

S = 4  # во сколько раз рисуем крупнее логического размера (чёткость на Retina)


def load_icon(name, size):
    p = os.path.join(ICON_DIR, f"{name}.png")
    try:
        im = Image.open(p).convert("RGBA")
        im = im.resize((size, size), Image.Resampling.LANCZOS)
        # скруглённые углы, чтобы квадратные иконки (Dust) смотрелись как остальные
        mask = Image.new("L", (size * 4, size * 4), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, size * 4 - 1, size * 4 - 1), radius=size * 4 * 0.22, fill=255)
        mask = mask.resize((size, size), Image.Resampling.LANCZOS)
        im.putalpha(Image.composite(im.getchannel("A"), Image.new("L", (size, size), 0), mask))
        return im
    except Exception:
        return Image.new("RGBA", (size, size), (0, 0, 0, 0))


def load_font(px):
    for path, idx in (("/System/Library/Fonts/SFNS.ttf", None), ("/System/Library/Fonts/Helvetica.ttc", 1)):
        try:
            f = ImageFont.truetype(path, px)
            try:
                f.set_variation_by_name("Semibold")
            except Exception:
                pass
            return f
        except Exception:
            continue
    return ImageFont.load_default()


def render(dark=False):
    items = [("claude", pct_of("claude")), ("dust", pct_of("dust")), ("muse", pct_of("muse"))]
    h = 16 * S
    icon = 14 * S
    gap = 3 * S
    sep = 8 * S
    font = load_font(13 * S)
    fg = (255, 255, 255, 235) if dark else (0, 0, 0, 255)

    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    width = sum(icon + gap + int(probe.textlength(t, font=font)) for _, t in items) + sep * (len(items) - 1)
    im = Image.new("RGBA", (width, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(im)
    x = 0
    for name, text in items:
        ic = load_icon(name, icon)
        im.paste(ic, (x, (h - icon) // 2), ic)
        x += icon + gap
        draw.text((x, h // 2), text, font=font, fill=fg, anchor="lm")
        x += int(draw.textlength(text, font=font)) + sep
    from io import BytesIO
    buf = BytesIO()
    im.save(buf, format="PNG", dpi=(72 * S, 72 * S))
    return base64.b64encode(buf.getvalue()).decode()


if __name__ == "__main__":
    try:
        # по умолчанию светлый текст (как системные значки на тёмной полосе меню);
        # AI_CREDITS_DARK=0 — тёмный текст для светлой полосы
        dark = os.environ.get("AI_CREDITS_DARK","1").strip().lower() not in ("0","false","no","light")
        sys.stdout.write(render(dark=dark))
    except Exception:
        sys.stdout.write("")
