#!/usr/bin/env python3
"""project/data/**/*.json 테이블을 project/data/schemas/*.schema.json 으로 검증한다.

외부 의존성 없이 돈다(JSON Schema의 자주 쓰는 부분집합: type, required, properties,
additionalProperties, items, enum, minimum, maximum, minItems, uniqueItems, pattern).
`jsonschema` 패키지가 설치되어 있으면 그것으로 전체 검증한다.

매핑 규칙: project/data/<table>/<file>.json  ↔  project/data/schemas/<table>.schema.json
스키마가 없는 테이블은 경고만 내고 통과시키되, --strict 면 실패로 본다.
CI와 커밋 hook이 같은 스크립트를 쓴다.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "project" / "data"
SCHEMAS = DATA / "schemas"


def _type_ok(v, t: str) -> bool:
    return {
        "object": isinstance(v, dict),
        "array": isinstance(v, list),
        "string": isinstance(v, str),
        "integer": isinstance(v, int) and not isinstance(v, bool),
        "number": isinstance(v, (int, float)) and not isinstance(v, bool),
        "boolean": isinstance(v, bool),
        "null": v is None,
    }.get(t, True)


def _validate(v, schema: dict, path: str, errors: list[str], defs: dict) -> None:
    if "$ref" in schema:
        ref = schema["$ref"]
        target = defs.get(ref.split("/")[-1])
        if target is None:
            errors.append(f"{path}: 알 수 없는 $ref {ref}")
            return
        _validate(v, target, path, errors, defs)
        return
    t = schema.get("type")
    if t:
        types = t if isinstance(t, list) else [t]
        if not any(_type_ok(v, x) for x in types):
            errors.append(f"{path}: 타입 {types} 이어야 하는데 {type(v).__name__}")
            return
    if "enum" in schema and v not in schema["enum"]:
        errors.append(f"{path}: {v!r} 는 허용 값 {schema['enum']} 에 없음")
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        if "minimum" in schema and v < schema["minimum"]:
            errors.append(f"{path}: {v} < minimum {schema['minimum']}")
        if "maximum" in schema and v > schema["maximum"]:
            errors.append(f"{path}: {v} > maximum {schema['maximum']}")
    if isinstance(v, str) and "pattern" in schema and not re.search(schema["pattern"], v):
        errors.append(f"{path}: {v!r} 가 패턴 {schema['pattern']} 과 맞지 않음")
    if isinstance(v, dict):
        for k in schema.get("required", []):
            if k not in v:
                errors.append(f"{path}: 필수 키 '{k}' 없음")
        props = schema.get("properties", {})
        for k, sub in props.items():
            if k in v:
                _validate(v[k], sub, f"{path}.{k}", errors, defs)
        if schema.get("additionalProperties") is False:
            for k in v:
                if k not in props:
                    errors.append(f"{path}: 허용되지 않은 키 '{k}'")
    if isinstance(v, list):
        if "minItems" in schema and len(v) < schema["minItems"]:
            errors.append(f"{path}: 항목 {len(v)}개 < minItems {schema['minItems']}")
        if schema.get("uniqueItems"):
            seen = set()
            for i, item in enumerate(v):
                key = json.dumps(item, sort_keys=True, ensure_ascii=False)
                if key in seen:
                    errors.append(f"{path}[{i}]: 중복 항목")
                seen.add(key)
        if "items" in schema:
            for i, item in enumerate(v):
                _validate(item, schema["items"], f"{path}[{i}]", errors, defs)


def validate(doc, schema: dict) -> list[str]:
    try:
        import jsonschema  # type: ignore

        v = jsonschema.Draft202012Validator(schema)
        return [f"{'/'.join(map(str, e.absolute_path)) or '$'}: {e.message}" for e in v.iter_errors(doc)]
    except ImportError:
        errors: list[str] = []
        _validate(doc, schema, "$", errors, schema.get("$defs", {}))
        return errors


def check_unique_ids(doc, path: str, errors: list[str]) -> None:
    """최상위 배열의 항목에 id 가 있으면 파일 안에서 유일해야 한다."""
    rows = doc if isinstance(doc, list) else doc.get("rows") if isinstance(doc, dict) else None
    if not isinstance(rows, list):
        return
    seen: dict[str, int] = {}
    for i, r in enumerate(rows):
        if isinstance(r, dict) and "id" in r:
            if r["id"] in seen:
                errors.append(f"{path}: id '{r['id']}' 중복 (행 {seen[r['id']]} 과 {i})")
            seen[r["id"]] = i


def main(argv: list[str]) -> int:
    strict = "--strict" in argv
    if not DATA.exists():
        print("project/data 없음 → 검증할 테이블 없음")
        return 0
    failed = 0
    checked = 0
    for f in sorted(DATA.rglob("*.json")):
        rel = f.relative_to(ROOT).as_posix()
        if f.parent == SCHEMAS:
            try:
                json.loads(f.read_text(encoding="utf-8"))
            except Exception as e:
                print(f"FAIL {rel}: 스키마 JSON 파싱 실패: {e}")
                failed += 1
            continue
        try:
            doc = json.loads(f.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"FAIL {rel}: JSON 파싱 실패: {e}")
            failed += 1
            continue
        table = f.relative_to(DATA).parts[0] if f.parent != DATA else f.stem
        schema_path = SCHEMAS / f"{table}.schema.json"
        errors: list[str] = []
        check_unique_ids(doc, rel, errors)
        if schema_path.exists():
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
            errors += validate(doc, schema)
            checked += 1
        else:
            msg = f"WARN {rel}: 스키마 없음 ({schema_path.relative_to(ROOT).as_posix()})"
            if strict:
                errors.append(msg)
            else:
                print(msg)
        if errors:
            failed += 1
            print(f"FAIL {rel}")
            for e in errors:
                print(f"   - {e}")
        else:
            print(f"ok   {rel}")
    print(f"\n{checked}개 테이블 스키마 검증, 실패 {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
