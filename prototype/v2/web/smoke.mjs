// SE-070 헤드리스 클릭 스모크: 빌드한 HTML 로 런을 끝까지 돌리고 콘솔 오류·가로 넘침을 확인한다.
// HTML 은 Artifact 게시 스켈레톤과 같은 head(charset + viewport-fit=cover)로 감싸 연다.
// 단정: 375px 에서 시드 12345 런 → '같은 시드로 다시' 런의 기록이 같다(AC1·AC2 결정성), 돌발 모달이 1회 이상 떴다,
// 배속·일시정지가 동작한다, 런이 알려진 결과 문구로 끝난다, 콘솔 오류·가로 넘침 0(AC4).
// 실행: NODE_PATH=$(npm root -g) node prototype/v2/web/smoke.mjs <built.html> [스크린샷 폴더] [런 수]
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const [file, shotDir, runsArg] = process.argv.slice(2);
const runs = +(runsArg || 3);
const wrapped = (await import("node:path")).resolve(file.replace(/\.html$/, ".wrapped.html"));
writeFileSync(wrapped, `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"></head><body>${readFileSync(file, "utf8")}</body></html>`);
if (shotDir) mkdirSync(shotDir, { recursive: true });

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined });
const errors = [];
const results = [];
const KNOWN = ["자금이 바닥났다", "다음 공연을 열 돈이 없다", "아무도 이름을 기억하지 않는다", "결산 무대에서 증명하지 못했다", "1막 통과"];
const histories = [];
let modals = 0, usedSpeed = false;
for (const [w, h, scheme] of [[375, 812, "light"], [1280, 900, "dark"]]) {
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
    if (r === 0) await page.evaluate(() => window.stageEmpireTest.startRun(12345));
    else if (r === 1) { if (!(await page.locator('[data-act="same-run"]').count())) { errors.push(`${w}: run0 did not reach the end screen`); break; } await page.click('[data-act="same-run"]'); }
    else await page.click('[data-act="new-run"]');
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
        // 그래도 안 되면 더 싼 헤드라이너를 차례로 시도
        const heads = page.locator('[data-act="head"]');
        for (let i = 1; i < await heads.count() && await go.isDisabled(); i++) await heads.nth(i).click();
        if (await go.isDisabled()) { errors.push(`${w}: cannot start show`); break; }
        await go.click();
      }
      else if (screen === "show") {
        if (!usedSpeed) {
          // 배속·일시정지 확인: 4× 를 누르고, 일시정지 → 재생
          await page.click('[data-act="speed"][data-x="4"]');
          const pressed = await page.getAttribute('[data-act="speed"][data-x="4"]', "aria-pressed");
          if (pressed !== "true") errors.push(`${w}: speed button not pressed`);
          await page.click('[data-act="play"]');
          if ((await page.textContent('[data-act="play"]')).trim() !== "재생") errors.push(`${w}: pause did not toggle`);
          await page.click('[data-act="play"]');
          usedSpeed = true;
        }
        await page.waitForTimeout(700); await shot("show");
        if (await page.locator(".modal").count()) continue; // 자동 진행 중 돌발이 떴다
        // 그사이 돌발 모달이 뜨거나 공연이 끝났으면 다음 바퀴에서 처리, 그 밖의 실패는 그대로 던진다
        await page.click('[data-act="skip"]', { timeout: 2000 }).catch(async (e) => {
          if (!(await page.locator(".modal").count()) && await page.locator('[data-act="skip"]').count()) throw e;
        });
      }
      else if (screen === "event") { modals++; await shot("event"); await page.locator(".modal .choice").first().click(); }
      else if (screen === "result") { await shot("result"); await page.click('[data-act="to-reward"], [data-act="to-over"]'); }
      else if (screen === "reward") { await shot("reward"); await page.locator(".rcard").first().click(); await page.click('[data-act="take"]'); }
      else if (screen === "over") {
        await shot("over");
        const txt = (await page.evaluate(() => document.querySelector(".lede")?.textContent || "")).trim();
        if (!KNOWN.some((k) => txt.startsWith(k))) errors.push(`${w}: unknown result text "${txt}"`);
        const hist = await page.evaluate(() => [window.stageEmpireTest.seed(), window.stageEmpireTest.history()]);
        if (w < 500 && r < 2) histories.push(hist);
        results.push(`${w} run${r}: seed ${hist[0]} ${txt} | ${JSON.stringify(hist[1])}`);
        break;
      } else { errors.push(`${w}: unknown screen`); break; }
    }
  }
  await page.close();
}
await browser.close();
if (histories.length !== 2 || JSON.stringify(histories[0]) !== JSON.stringify(histories[1])) errors.push("same-seed rerun differs: " + JSON.stringify(histories));
if (modals === 0) errors.push("no event modal seen");
results.push(`event modals: ${modals}`);
console.log(results.join("\n"));
console.log(errors.length ? "ERRORS:\n" + errors.join("\n") : "no errors");
process.exit(errors.length ? 1 : 0);
