// SE-070 단일 HTML 빌드: engine.js + web/app.js + style.css + 데이터 JSON 을 한 파일로 합친다.
// 실행: node prototype/v2/web/build.mjs [출력 경로]  (기본 prototype/v2/web/dist/stage-empire-v2.html)
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadData } from "../load_data.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const out = process.argv[2] || join(here, "dist/stage-empire-v2.html");
const engine = readFileSync(join(here, "../engine.js"), "utf8");
const app = readFileSync(join(here, "app.js"), "utf8").replace(/^import .*$/gm, "");
const data = JSON.stringify(loadData()).replace(/</g, "\\u003c");
const html = readFileSync(join(here, "template.html"), "utf8")
  .replace("/*STYLE*/", () => readFileSync(join(here, "style.css"), "utf8"))
  .replace("/*DATA*/", () => data)
  .replace("/*SCRIPT*/", () => engine + "\n" + app);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, html);
console.log(out, html.length, "bytes");
