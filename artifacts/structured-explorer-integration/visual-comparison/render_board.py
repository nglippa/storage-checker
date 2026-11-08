"""Compose unaltered offscreen captures; never synthesize or retouch application pixels."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import shutil

here = Path(__file__).resolve().parent
root = here.parent
reference = Path.home() / 'storage-checker-lt-research/artifacts/storage-monitor-living-tree-research/PROTOTYPE-B/screenshots'
shots = root / 'headless-renders'
refs = here / 'selected-prototype-b'
refs.mkdir(exist_ok=True)
rows = [
    ('Overview · dark', 'B-structured-1-overview-dark.png', 'new-01-overview-dark.png', 'old-01-overview-dark.png'),
    ('Users selected · dark', 'B-structured-2-large-selection-dark.png', 'new-02-large-selected-dark.png', 'old-02-large-selected-dark.png'),
    ('Deep selection · light', 'B-structured-3-deep-selection-light.png', 'new-03-deep-selected-light.png', 'old-03-deep-selected-light.png'),
]
for _, filename, _, _ in rows:
    shutil.copy2(reference / filename, refs / filename)
font_path = '/System/Library/Fonts/Supplemental/Arial.ttf'
font = ImageFont.truetype(font_path, 19)
small = ImageFont.truetype(font_path, 15)
cell_w, cell_h, gap, top, caption = 720, 450, 18, 100, 30
board = Image.new('RGB', (3 * cell_w + 4 * gap, top + len(rows) * (cell_h + caption + gap) + 35), '#e9e7e1')
draw = ImageDraw.Draw(board)
draw.text((gap, 12), 'Storage Monitor · selected Structured Explorer integration', font=font, fill='#181818')
for col, title in enumerate(['Selected Prototype B · source reference', 'Integrated B · default Living Tree', 'Classic Living Tree · reversible fallback']):
    draw.text((gap + col * (cell_w + gap), 57), title, font=small, fill='#353535')
for row, (title, source, new, old) in enumerate(rows):
    y = top + row * (cell_h + caption + gap)
    for col, path in enumerate([refs / source, shots / new, shots / old]):
        image = Image.open(path).convert('RGB')
        image.thumbnail((cell_w, cell_h), Image.Resampling.LANCZOS)
        x = gap + col * (cell_w + gap)
        board.paste(image, (x, y))
        draw.text((x, y + cell_h + 5), title if col < 2 else title.replace("· light", "· classic dark canvas"), font=small, fill='#353535')
draw.text((gap, board.height - 28), 'Offscreen hosted views; no desktop input or native interaction success is implied. Full-resolution originals accompany this board.', font=small, fill='#353535')
board.save(here / 'integration-board.png')
print(here / 'integration-board.png')
