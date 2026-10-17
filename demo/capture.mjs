// Renders scene.html frame by frame into frames/NNNN.png.
// Usage: node capture.mjs [fps=30] [scale=1] [onlyAtSeconds,comma,separated]
import { chromium } from "playwright";
import { mkdirSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const [fps = "30", scale = "1", only] = process.argv.slice(2);
const dir = fileURLToPath(new URL("./frames/", import.meta.url));
rmSync(dir, { recursive: true, force: true });
mkdirSync(dir);

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: Number(scale) });
await page.addInitScript(() => { window.__capture = true; });
await page.goto(new URL("./scene.html", import.meta.url).href);
await page.evaluate(() => document.fonts.ready);

const duration = await page.evaluate(() => DURATION);
const times = only ? only.split(",").map(Number) : [...Array(Math.round(duration * Number(fps))).keys()].map(i => i / Number(fps));
for (const [i, t] of times.entries()) {
  await page.evaluate(t => window.render(t), t);
  await page.screenshot({ path: `${dir}${String(i).padStart(4, "0")}.png` });
}
await browser.close();
console.log(`${times.length} frames → ${dir}`);
