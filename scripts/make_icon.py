#!/usr/bin/env python3
"""앱 아이콘 "모아"를 그린다 (1024×1024, 투명 없음).

네 칸 격자(흰 잎 · 반짝임이 든 민트 동그라미 · 민트 잎 · 흰 잎)를 수치로 그려,
칸 크기·간격·모서리가 정확히 맞게 한다. 쓰는 법:

    python3 scripts/make_icon.py MeetingSummary/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
"""
import sys

import numpy as np
from PIL import Image

SIZE = 1024
SCALE = 4  # 크게 그려서 줄인다 (가장자리를 매끄럽게)

BACKGROUND = (15, 15, 18)
MINT = (68, 217, 172)
WHITE = (255, 255, 255)

CELL = 322        # 한 칸의 변
GAP = 32          # 칸 사이
BIG = 150         # 잎의 둥근 모서리
SMALL = 26        # 잎의 각진 모서리
SPARK = 84        # 반짝임의 중심에서 끝까지
SPARK_POWER = 0.61  # |x|^p + |y|^p = R^p — 작을수록 가늘다


def leaf(xx, yy, x0, y0, tl, tr, br, bl):
    """모서리마다 둥글기가 다른 네모. 반지름은 (왼쪽 위, 오른쪽 위, 오른쪽 아래, 왼쪽 아래)."""
    x1, y1 = x0 + CELL, y0 + CELL
    inside = (xx >= x0) & (xx < x1) & (yy >= y0) & (yy < y1)
    for r, cx, cy, sx, sy in ((tl, x0 + tl, y0 + tl, -1, -1), (tr, x1 - tr, y0 + tr, 1, -1),
                              (br, x1 - br, y1 - br, 1, 1), (bl, x0 + bl, y1 - bl, -1, 1)):
        corner = ((xx - cx) * sx > 0) & ((yy - cy) * sy > 0)
        inside &= ~(corner & ((xx - cx) ** 2 + (yy - cy) ** 2 > r * r))
    return inside


def main(path):
    n = SIZE * SCALE
    axis = (np.arange(n) + 0.5) / SCALE
    xx, yy = np.meshgrid(axis, axis)
    image = np.empty((n, n, 3), dtype=np.uint8)
    image[:] = BACKGROUND

    start = (SIZE - (2 * CELL + GAP)) / 2
    left, top = start, start
    right, bottom = start + CELL + GAP, start + CELL + GAP

    image[leaf(xx, yy, left, top, BIG, SMALL, BIG, SMALL)] = WHITE
    image[leaf(xx, yy, left, bottom, SMALL, BIG, SMALL, BIG)] = MINT
    image[leaf(xx, yy, right, bottom, SMALL, BIG, SMALL, BIG)] = WHITE

    cx, cy, radius = right + CELL / 2, top + CELL / 2, CELL / 2
    image[(xx - cx) ** 2 + (yy - cy) ** 2 <= radius * radius] = MINT
    spark = np.abs(xx - cx) ** SPARK_POWER + np.abs(yy - cy) ** SPARK_POWER <= SPARK ** SPARK_POWER
    image[spark] = WHITE

    Image.fromarray(image, "RGB").resize((SIZE, SIZE), Image.LANCZOS).save(path, optimize=True)


if __name__ == "__main__":
    main(sys.argv[1])
