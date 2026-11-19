#!/usr/bin/env python3
"""앱 아이콘을 강조색마다 라이트·다크·색조로 만든다 (D144·D146).

원본(scripts/icon-source/AppIcon-source.png: 어두운 바탕·흰 잎·민트)의 픽셀을
"어두운 바탕 + 흰색 몫 + 민트 몫"으로 풀고, 몫은 그대로 둔 채 색만 바꿔 다시 칠한다
(가장자리의 부드러움이 그대로 남는다). 민트 원 안의 흰 별은 어느 모드에서나 흰색이다.

    python3 scripts/app_icons.py            # Assets.xcassets 안의 AppIcon*.appiconset을 다시 만든다
    python3 scripts/app_icons.py --preview out.png   # 미리보기 한 장만 만든다

색을 더하려면 COLORS에 한 줄, AppTheme.swift의 AccentChoice에 한 줄, project.yml의 대체 아이콘 이름에 하나를 더한다.
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, 'scripts/icon-source/AppIcon-source.png')
ASSETS = os.path.join(ROOT, 'MeetingSummary/Resources/Assets.xcassets')

# 이름: (세트 이름, 아이콘 색 = AccentChoice.bright)
COLORS = [
    ('민트', 'AppIcon', '45D9AD'),
    ('블루', 'AppIcon-Blue', '5AA9FF'),
    ('바이올렛', 'AppIcon-Violet', 'A98BFF'),
    ('코랄', 'AppIcon-Coral', 'FF8A7A'),
    ('오렌지', 'AppIcon-Orange', 'FFB35C'),
    ('핑크', 'AppIcon-Pink', 'FF7EB6'),
]

DARK_BG, WHITE, MINT = (15, 15, 18), (255, 255, 255), (68, 217, 172)
# 라이트: 흰 바탕, 먹색 잎 (앱 안 로고의 밝은 모드와 같은 #16191E)
LIGHT_BG, LIGHT_LEAF = (255, 255, 255), (22, 25, 30)
# 색조: 시스템이 물들이는 흑백. 바탕은 검정, 잎은 회색, 강조 부분이 가장 밝다
TINT_BG, TINT_LEAF, TINT_ACCENT = (0, 0, 0), (150, 150, 150), (235, 235, 235)
# 민트 원 (별이 들어 있는 원): 원본 1024 기준 중심과 반지름
STAR_CIRCLE = (688, 335, 165)


def hex_rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def decompose(path):
    im = np.asarray(Image.open(path).convert('RGB')).astype(np.float64)
    h, w = im.shape[:2]
    d, wh, m = map(np.array, (DARK_BG, WHITE, MINT))
    basis = np.stack([wh - d, m - d], axis=1).astype(float)
    coef, *_ = np.linalg.lstsq(basis, (im.reshape(-1, 3) - d).T, rcond=None)
    white, accent = np.clip(coef[0], 0, 1), np.clip(coef[1], 0, 1)
    total = white + accent
    over = total > 1
    white[over] /= total[over]
    accent[over] /= total[over]
    yy, xx = np.mgrid[0:h, 0:w]
    cx, cy, r = STAR_CIRCLE
    in_circle = (((xx - cx) ** 2 + (yy - cy) ** 2) < r ** 2).reshape(-1)
    return (h, w), white, accent, in_circle


def paint(parts, bg, leaf, star, accent_color):
    (h, w), white, accent, in_circle = parts
    bg, leaf, star, accent_color = (np.array(c, float) for c in (bg, leaf, star, accent_color))
    white_to = np.where(in_circle[:, None], star, leaf)
    px = bg + white[:, None] * (white_to - bg) + accent[:, None] * (accent_color - bg)
    return Image.fromarray(np.clip(px, 0, 255).reshape(h, w, 3).astype(np.uint8))


def variants(parts, color):
    c = hex_rgb(color)
    return {
        'light': paint(parts, LIGHT_BG, LIGHT_LEAF, WHITE, c),
        'dark': paint(parts, DARK_BG, WHITE, WHITE, c),
        'tinted': paint(parts, TINT_BG, TINT_LEAF, TINT_BG, TINT_ACCENT),
    }


def write_sets(parts):
    for _, name, color in COLORS:
        folder = os.path.join(ASSETS, f'{name}.appiconset')
        os.makedirs(folder, exist_ok=True)
        for old in os.listdir(folder):
            if old.endswith('.png'):
                os.remove(os.path.join(folder, old))
        images = []
        for kind, image in variants(parts, color).items():
            filename = f'{name}-{kind}.png'
            image.save(os.path.join(folder, filename), optimize=True)
            entry = {'filename': filename, 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}
            if kind != 'light':
                entry['appearances'] = [{'appearance': 'luminosity', 'value': kind}]
            images.append(entry)
        with open(os.path.join(folder, 'Contents.json'), 'w') as f:
            json.dump({'images': images, 'info': {'author': 'xcode', 'version': 1}}, f, indent=2)
        print('wrote', folder)


def preview(parts, out):
    size, gap, label_h = 150, 24, 34
    cols = len(COLORS)
    width = gap + cols * (size + gap)
    rows = [('라이트 모드', (242, 242, 247), (60, 60, 67), 'light'), ('다크 모드', (28, 28, 30), (235, 235, 240), 'dark')]
    sheet = Image.new('RGB', (width, len(rows) * (size + label_h * 2 + gap) + gap))
    try:
        font = ImageFont.truetype('/System/Library/Fonts/AppleSDGothicNeo.ttc', 20)
    except OSError:
        font = ImageFont.load_default()
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * 0.225), fill=255)
    all_variants = [variants(parts, color) for _, _, color in COLORS]
    for r, (title, bg, fg, kind) in enumerate(rows):
        top = r * (size + label_h * 2 + gap)
        draw = ImageDraw.Draw(sheet)
        draw.rectangle((0, top, width, top + size + label_h * 2 + gap), fill=bg)
        draw.text((gap, top + 8), title, font=font, fill=fg)
        for i, (label, _, _) in enumerate(COLORS):
            x = gap + i * (size + gap)
            sheet.paste(all_variants[i][kind].resize((size, size), Image.LANCZOS), (x, top + label_h), mask)
            draw.text((x + size // 2, top + label_h + size + 6), label, font=font, fill=fg, anchor='ma')
    sheet.save(out)
    print('preview', out)


if __name__ == '__main__':
    parts = decompose(SOURCE)
    if len(sys.argv) > 2 and sys.argv[1] == '--preview':
        preview(parts, sys.argv[2])
    else:
        write_sets(parts)
