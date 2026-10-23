import sys, subprocess, os, shutil
from playwright.sync_api import sync_playwright
name, out = sys.argv[1], sys.argv[2]
only = float(sys.argv[3]) if len(sys.argv) > 3 else None
here = os.path.dirname(os.path.abspath(__file__))
frames = os.path.join(here, 'frames-' + name)
shutil.rmtree(frames, ignore_errors=True); os.makedirs(frames)
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={'width': 1280, 'height': 800}, device_scale_factor=1.5)
    pg.goto('file://' + os.path.join(here, 'demo.html'))
    pg.wait_for_timeout(300)
    if only is not None:
        pg.evaluate(f"render('{name}', {only})"); pg.screenshot(path=out); b.close(); sys.exit(0)
    dur = pg.evaluate(f"duration('{name}')")
    fps = 30
    n = int(dur * fps)
    for i in range(n):
        pg.evaluate(f"render('{name}', {i / fps})")
        pg.screenshot(path=os.path.join(frames, f'{i:04d}.png'))
    b.close()
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', '30', '-i', os.path.join(frames, '%04d.png'),
                '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '20', '-preset', 'medium', '-movflags', '+faststart', out], check=True)
shutil.rmtree(frames)
