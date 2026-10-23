"""Renders Bremorph's brand assets with Chromium (Playwright).

    python3 docs/brand/make_brand.py <out-dir>

Writes icon-1024.png, the AppIcon.iconset sizes, MenuBarIcon(.png/@2x) and banner.png.

The mark is a "B" whose top bowl is a document with a folded corner and whose bottom bowl is round:
a file going in square and coming out changed. Palette: graphite + signal lime (see Sources/Brand.swift).
"""
import asyncio, math, os, sys
from playwright.async_api import async_playwright

LIME = "#C9F23E"
INK = "#101211"
LIME_FOLD = "#8DA92A"
GRAPHITE_TOP = "#2A2D30"
GRAPHITE_BOTTOM = "#121416"


def squircle(cx, cy, r, n=5.0, steps=720):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = cx + r * math.copysign(abs(c) ** (2 / n), c)
        y = cy + r * math.copysign(abs(s) ** (2 / n), s)
        pts.append(f"{x:.2f},{y:.2f}")
    return "M" + " L".join(pts) + " Z"


# The mark, drawn as one 80-unit stroke on a 1024 grid (centre line coordinates).
MARK = ("M340,290 H560 L640,370 V500 H340 "        # top bowl: a page with its corner folded
        "M340,500 H560 A137,137 0 0 1 560,774 H340 "  # bottom bowl: round
        "M340,250 V814")                              # stem
MARK_W = 80


def mark_svg(color, stroke=MARK_W, extra=""):
    return (f'<path d="{MARK}" fill="none" stroke="{color}" stroke-width="{stroke}" '
            f'stroke-linejoin="miter" stroke-miterlimit="4" stroke-linecap="butt" {extra}/>')


def icon_svg(size=1024):
    sq = squircle(512, 512, 412)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{GRAPHITE_TOP}"/><stop offset="1" stop-color="{GRAPHITE_BOTTOM}"/>
    </linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".22"/>
      <stop offset=".25" stop-color="#ffffff" stop-opacity=".04"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity=".02"/>
    </linearGradient>
    <filter id="grain" x="0" y="0" width="100%" height="100%">
      <feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" seed="7" result="n"/>
      <feColorMatrix type="saturate" values="0"/>
      <feComponentTransfer><feFuncA type="linear" slope=".09"/></feComponentTransfer>
      <feComposite in2="SourceGraphic" operator="in"/>
    </filter>
    <filter id="drop" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="14"/>
    </filter>
    <filter id="markshadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="6" stdDeviation="8" flood-color="#000" flood-opacity=".45"/>
    </filter>
    <clipPath id="sq"><path d="{sq}"/></clipPath>
  </defs>
  <path d="{sq}" fill="#000" opacity=".38" filter="url(#drop)" transform="translate(0 12)"/>
  <path d="{sq}" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="#fff" filter="url(#grain)" clip-path="url(#sq)"/>
  <g clip-path="url(#sq)">
    <!-- a faint baseline grid: the page the file sits on -->
    <g stroke="#ffffff" stroke-opacity=".035" stroke-width="2">
      {''.join(f'<line x1="0" y1="{y}" x2="1024" y2="{y}"/>' for y in range(162, 900, 58))}
    </g>
  </g>
  <path d="{sq}" fill="none" stroke="url(#rim)" stroke-width="4"/>
  <g transform="translate(512 512) scale(.86) translate(-518 -532)" filter="url(#markshadow)">
    {mark_svg(LIME)}
    <!-- the folded-over corner of the page -->
    <path d="M520,330 L600,410 H520 Z" fill="{LIME_FOLD}"/>
  </g>
</svg>"""


def menubar_svg(px):
    # Template image: black mark on transparent, tightened to the glyph's bounds.
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{px}" height="{px}" viewBox="270 230 470 600">
  {mark_svg('#000', stroke=96)}
</svg>"""


def banner_html():
    sq = squircle(512, 512, 412)
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
  html,body{{margin:0;width:1280px;height:640px;overflow:hidden;background:#111315}}
  body{{font-family:-apple-system,'SF Pro Display','Inter','Helvetica Neue',Arial,sans-serif;color:#EDEFEA}}
  .grid{{position:absolute;inset:0;background-image:linear-gradient(rgba(255,255,255,.035) 1px,transparent 1px),
        linear-gradient(90deg,rgba(255,255,255,.035) 1px,transparent 1px);background-size:40px 40px}}
  .icon{{position:absolute;left:88px;top:150px;width:340px;height:340px}}
  .text{{position:absolute;left:480px;top:178px;right:80px}}
  h1{{margin:0;font-size:96px;font-weight:700;letter-spacing:-3px;line-height:1}}
  h1 span{{color:{LIME}}}
  p{{margin:22px 0 0;font-size:30px;line-height:1.35;color:#B9BDB5;font-weight:400}}
  .ar{{direction:rtl;text-align:left;font-family:'Geeza Pro','Noto Naskh Arabic','Noto Sans Arabic',sans-serif;font-size:25px;color:#8E938A;margin-top:14px;white-space:nowrap}}
  .chips{{margin-top:40px;display:flex;gap:10px;flex-wrap:wrap}}
  .chip{{font-family:'SF Mono','JetBrains Mono','DejaVu Sans Mono',monospace;font-size:19px;padding:7px 13px;border-radius:9px;
        border:1px solid rgba(255,255,255,.14);color:#D9DCD4}}
  .chip.on{{background:{LIME};color:{INK};border-color:{LIME};font-weight:700}}
  .foot{{position:absolute;left:88px;bottom:44px;font-family:'SF Mono','DejaVu Sans Mono',monospace;font-size:17px;color:#6F746B;letter-spacing:.5px}}
</style></head><body>
<div class="grid"></div>
<div class="icon">{icon_svg(340)}</div>
<div class="text">
  <h1>Bremorph<span>.</span></h1>
  <p>Convert, compress and edit files from Finder.<br>Nothing leaves your Mac.</p>
  <p class="ar">حوّل ملفاتك واضغطها وعدّلها من Finder، دون أن تغادر جهازك.</p>
  <div class="chips">
    <span class="chip">.heic</span><span class="chip">.pdf</span><span class="chip">.mov</span>
    <span class="chip on">→ .webp</span><span class="chip">.docx</span><span class="chip">.mp3</span>
  </div>
</div>
<div class="foot">macOS 13+ · English / العربية · MIT · by Mohammed Bremoo</div>
</body></html>"""


async def shot(page, html, path, w, h, transparent=True):
    await page.set_viewport_size({"width": w, "height": h})
    await page.set_content(html)
    await page.wait_for_timeout(150)
    await page.screenshot(path=path, omit_background=transparent)


async def main(out):
    os.makedirs(out, exist_ok=True)
    iconset = os.path.join(out, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    async with async_playwright() as p:
        b = await p.chromium.launch()
        page = await b.new_page()
        wrap = lambda svg, s: f"<html><body style='margin:0;background:transparent'>{svg}</body></html>"
        await shot(page, wrap(icon_svg(1024), 1024), os.path.join(out, "icon-1024.png"), 1024, 1024)
        for base in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = base * scale
                name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
                await shot(page, wrap(icon_svg(px), px), os.path.join(iconset, name), px, px)
        await shot(page, wrap(menubar_svg(18), 18), os.path.join(out, "MenuBarIcon.png"), 18, 18)
        await shot(page, wrap(menubar_svg(36), 36), os.path.join(out, "MenuBarIcon@2x.png"), 36, 36)
        hi = await b.new_page(device_scale_factor=2)   # banner at 2x so it stays sharp on Retina screens and in X previews
        await shot(hi, banner_html(), os.path.join(out, "banner.png"), 1280, 640, transparent=False)
        await b.close()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "brand-out"))
