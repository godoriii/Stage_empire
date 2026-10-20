// node 전용: docs/gdd/v2/data/*.json 을 읽어 엔진 data 객체로 묶는다.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const DATA_DIR = join(dirname(fileURLToPath(import.meta.url)), "../../docs/gdd/v2/data");
export const TABLES = ["balance", "acts", "venues", "artists", "staff", "facilities", "events", "rewards"];

export function loadData(dir = DATA_DIR) {
  const d = {};
  for (const t of TABLES) d[t] = JSON.parse(readFileSync(join(dir, t + ".json"), "utf8"));
  return d;
}
