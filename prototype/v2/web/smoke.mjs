// SE-070 헤드리스 클릭 스모크: 빌드한 HTML 로 런을 끝까지 돌리고 콘솔 오류·가로 넘침을 확인한다.
// 실행: NODE_PATH=$(npm root -g) node prototype/v2/web/smoke.mjs <built.html> [스크린샷 폴더] [런 수]
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const [file, shotDir, runsArg] = process.argv.slice(2);
const runs = +(runsArg || 3);
const wrapped = (await import("node:path")).resolve(file.replace(/\.html$/, ".wrapped.html"));
writeFileSync(wrapped, `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"></head><body>${readFileSync(file, "utf8")}</body></html>`);
if (shotDir) mkdirSync(shotDir, { recursive: true });

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined });
const errors = [];
const results = [];
for (const [w, h, scheme] of [[390, 844, "light"], [1280, 900, "dark"]]) {
  const page = await browser.newPage({ viewport: { width: w, height: h }, colorScheme: scheme });
  page.on("console", (m) => { if (m.type() === "error" && !/fonts\.g/.test(m.text())) errors.push(`${w} console: ${m.text()}`); });
  page.on("pageerror", (e) => errors.push(`${w} pageerror: ${e.message}`));
  await page.goto("file://" + wrapped);
  const shots = new Set();
  const shot = async (name) => {
    if (!shotDir || shots.has(name)) return;
    shots.add(name);
    await page.screenshot({ path: `${shotDir}/${w}-${name}.png`, fullPage: name !== "show" });
  };
  const overflow = async (name) => {
    const o = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    if (o > 0) errors.push(`${w} ${name}: horizontal overflow ${o}px`);
  };
  await shot("title");
  for (let r = 0; r < (w < 500 ? runs : 1); r++) {
    await page.click('[data-act="new-run"]');
    for (let guard = 0; guard < 200; guard++) {
      const screen = await page.evaluate(() => {
        const q = (s) => document.querySelector(s);
        if (q(".modal")) return "event";
        if (q('[data-act="offer"]')) return "offer";
        if (q('[data-act="venue"]')) return "plan";
        if (q('[data-act="skip"]')) return "show";
        if (q('[data-act="to-reward"], [data-act="to-over"]')) return "result";
        if (q('[data-act="take"]')) return "reward";
        if (q('[data-act="same-run"]')) return "over";
        return "unknown";
      });
      await overflow(screen);
      if (screen === "offer") { await shot("offer"); await page.click('[data-act="offer"]'); }
      else if (screen === "plan") {
        // 시장 첫 아티스트를 헤드라이너로, 경고가 사라질 때까지 손잡이를 올린다
        await page.click('[data-act="head"]');
        for (let k = 0; k < 8; k++) {
          const warn = await page.evaluate(() => [...document.querySelectorAll(".stepper")].map((s) => !!s.querySelector(".warn-line")));
          let changed = false;
          for (let i = 0; i < warn.length; i++) {
            if (!warn[i]) continue;
            const b = page.locator(".stepper").nth(i).locator('[data-d="1"]');
            if (await b.isEnabled()) { await b.click(); changed = true; }
          }
          if (!changed) break;
        }
        await shot("plan");
        const go = page.locator(w < 900 ? '.dock [data-act="go"]' : '.preview [data-act="go"]');
        if (await go.isDisabled()) {
          // 예산이 모자라면 가장 작은 장소로
          await page.locator('[data-act="venue"]').first().click();
          for (const k of ["security", "bar", "toilet"]) {
            const minus = page.locator(`[data-act="step"][data-k="${k}"][data-d="-1"]`);
            while (await minus.isEnabled() && await go.isDisabled()) await minus.click();
          }
        }
        if (await go.isDisabled()) { errors.push(`${w}: cannot start show`); break; }
        await go.click();
      }
      else if (screen === "show") {
        await page.waitForTimeout(700); await shot("show");
        if (await page.locator(".modal").count()) continue; // 자동 진행 중 돌발이 떴다
        await page.click('[data-act="skip"]');
      }
      else if (screen === "event") { await shot("event"); await page.locator(".modal .choice").first().click(); }
      else if (screen === "result") { await shot("result"); await page.click('[data-act="to-reward"], [data-act="to-over"]'); }
      else if (screen === "reward") { await shot("reward"); await page.locator(".rcard").first().click(); await page.click('[data-act="take"]'); }
      else if (screen === "over") {
        await shot("over");
        const txt = await page.evaluate(() => document.querySelector(".lede")?.textContent || "");
        results.push(`${w}: ${txt.trim()}`);
        break;
      } else { errors.push(`${w}: unknown screen`); break; }
    }
  }
  await page.close();
}
await browser.close();
console.log(results.join("\n"));
console.log(errors.length ? "ERRORS:\n" + errors.join("\n") : "no errors");
process.exit(errors.length ? 1 : 0);
