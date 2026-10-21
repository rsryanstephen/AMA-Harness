#!/usr/bin/env python3
"""Mechanical review of a rendered Terraform plan (text, ANSI already stripped).

usage: plan-review.py <plan-text-file> [<previous-plan-text-file>]

Prints a report with three sections and exits 0 (report produced) / 2 (no plan found):
  BLOCKERS      -- destroy/replace of a stateful resource, plan error, unparseable plan
  TO EXPLAIN    -- every real change, list-shift noise already removed, for the user
  NOISE         -- what was filtered out and why (so the reader can check the filter)
The judgment half (is each change intended? reversible? dead paths really dead?) is the
reviewer's -- see SKILL.md "Before recommending a plan approval".
"""
import re, sys

STATEFUL = re.compile(r"aws_(db_instance|rds_cluster|rds_cluster_instance|s3_bucket|dynamodb_table|efs_file_system|"
                      r"elasticache_(cluster|replication_group)|docdb_cluster(_instance)?|kms_key|redshift_cluster|"
                      r"ebs_volume|secretsmanager_secret|cognito_user_pool|route53_zone|ecr_repository|"
                      r"sqs_queue|opensearch_domain|elasticsearch_domain)\b")
ORDERED = ("ordered_cache_behavior",)          # ordered lists whose removals shift every later slot


def load(p):
    out = []
    for l in open(p, encoding="utf-8", errors="replace"):
        l = re.sub(r"\x1b\[[0-9;]*m", "", l.rstrip("\n"))
        l = re.sub(r"^[0-9:]{8} +(Info|Verbose|Warning|Error) +\| ?", "", l)   # Octopus raw-log prefix
        out.append(l)
    return out


def resources(lines):
    """Split into (address, action, body-lines) per '# <addr> will be/must be' header."""
    res, cur = [], None
    for l in lines:
        m = re.match(r"\s*# (\S+) (will be (created|destroyed|updated in-place|read during apply)|must be replaced)", l)
        if m:
            cur = [m.group(1), m.group(2), []]; res.append(cur); continue
        if re.match(r"\s*Plan: ", l) or re.match(r"\s*(Changes to Outputs|─{5,})", l):
            cur = None
        elif cur is not None:
            cur[2].append(l)
    return res


def nested_blocks(body, name):
    """Yield (sign, lines) for each `name {` block at any depth."""
    out, cur, depth = [], None, 0
    for l in body:
        m = re.match(r"\s*([-+~]?)\s*" + re.escape(name) + r" \{", l)
        if m and cur is None:
            cur = (m.group(1) or " ", []); depth = 1; continue
        if cur is not None:
            depth += l.count("{") - l.count("}")
            if depth <= 0:
                out.append(cur); cur = None; continue
            cur[1].append(l)
    return out


def attrs(lines, side):
    """Flatten a block to a set of 'key = value' strings for the OLD (side='-') or NEW ('+') view.
    Multi-line lists (`key = [` ... `]`) collapse into one entry; per-item signs are honoured."""
    s, lst = set(), None          # lst = [key, header_sign, items]
    for l in lines:
        m = re.match(r"\s*([-+~]?)\s*(.*?)\s*$", l); sign, rest = m.group(1), m.group(2)
        if lst is not None:
            if rest.startswith("]"):
                hs = lst[1]
                if not ((hs == "+" and side == "-") or (hs == "-" and side == "+")
                        or (rest.endswith("-> null") and side == "+")):
                    s.add(lst[0] + " = [" + ",".join(sorted(lst[2])) + "]")
                lst = None
            elif not ((sign == "+" and side == "-") or (sign == "-" and side == "+")):
                lst[2].append(rest.rstrip(","))
            continue
        lm = re.match(r"(\w+)\s*=\s*\[$", rest)
        if lm: lst = [lm.group(1), sign, []]; continue
        if rest in ("{", "}") or rest.endswith("{") or rest.startswith("}"): continue
        if " -> " in rest:
            k, _, v = rest.partition("=")
            old, _, new = v.partition(" -> ")
            val = (old if side == "-" else new).strip()
            if val == "null": continue
            rest = k.strip() + " = " + val
        elif (sign == "+" and side == "-") or (sign == "-" and side == "+"):
            continue
        s.add(re.sub(r"\s+", " ", rest.rstrip(",")))
    return s


def review(lines, prev):
    blockers, explain, noise = [], [], []
    if any(re.search(r"^\s*Error: ", l) for l in lines):
        blockers.append("plan output contains 'Error:' -- read it before anything else")
    summ = [l.strip() for l in lines if re.match(r"\s*Plan: \d+ to add", l)]
    nochg = any("No changes." in l for l in lines)
    if not summ and not nochg:
        return None
    explain.append(summ[-1] if summ else "No changes.")
    for addr, act, body in resources(lines):
        typ = addr.split("[")[0].split(".")[-2] if "." in addr else addr
        if act in ("will be destroyed", "must be replaced") and STATEFUL.search(addr):
            why = [l.strip() for l in body if "forces replacement" in l][:3]
            blockers.append(f"{act.upper()}: {addr} (stateful){' -- ' + '; '.join(why) if why else ''}")
        elif act in ("will be destroyed", "must be replaced"):
            explain.append(f"{act}: {addr}")
        elif act == "will be created":
            explain.append(f"create: {addr}")
        if act != "will be updated in-place":
            continue
        handled = set()
        for name in ORDERED:
            blocks = nested_blocks(body, name)
            if not blocks: continue
            handled.add(name)
            def path(b, side):
                for l in b:
                    m = re.match(r'\s*[-+~]?\s*path_pattern\s+=\s+"([^"]*)"(?:\s+->\s+"([^"]*)")?', l)
                    if m: return m.group(1) if side == "-" or not m.group(2) else m.group(2)
            before = {path(b, "-"): frozenset(attrs(b, "-") - {a for a in attrs(b, "-") if a.startswith("path_pattern")}) for s, b in blocks if s != "+"}
            after = {path(b, "+"): frozenset(attrs(b, "+") - {a for a in attrs(b, "+") if a.startswith("path_pattern")}) for s, b in blocks if s != "-"}
            removed = sorted(k for k in before if k not in after); added = sorted(k for k in after if k not in before)
            settings = len(set(before.values()))
            explain.append(f"{addr}: {name} {len(before)} -> {len(after)}; REMOVED {removed or '-'}; ADDED {added or '-'}")
            changed = []
            if settings == 1 and len(set(after.values()) | set(before.values())) == 1:
                noise.append(f"{name}: {sum(1 for s, b in blocks if s == '~')} slot renames are list shift only -- all rules share identical settings")
            else:
                for k in sorted(set(before) & set(after)):
                    if before[k] != after[k]:
                        changed.append(f"{k}: {sorted(before[k] ^ after[k])[:6]}")
                if changed:
                    explain.append(f"{name} rules whose SETTINGS change (not just slot): " + " | ".join(changed))
                else:
                    noise.append(f"{name}: slot renames are list shift only -- every surviving path keeps its settings")
        for name in ("origin",):
            blocks = nested_blocks(body, name)
            if not blocks: continue
            handled.add(name)
            def dom(b):
                return next((re.sub(r"\s*->\s*null$", "", re.sub(r".*=\s*", "", l.strip())) for l in b if "domain_name" in l), "?")
            olds = {dom(b): attrs(b, "-") for s, b in blocks if s in ("-", "~", " ")}
            news = {dom(b): attrs(b, "+") for s, b in blocks if s in ("+", "~", " ")}
            for d in sorted(set(olds) | set(news)):
                o, n = olds.get(d, set()), news.get(d, set())
                if o == n: continue
                gone = sorted(o - n); new = sorted(n - o)
                explain.append(f"{addr}: origin {d}: was {gone or '-'} now {new or '-'}")
        # Remaining top-level changed attribute lines, outside the blocks handled above.
        depth, skip, other = 0, 0, []
        for l in body:
            opens = re.match(r"\s*[-+~]?\s*(\w+) \{", l)
            if skip:
                skip += l.count("{") - l.count("}")
                continue
            if opens and opens.group(1) in handled:
                skip = 1; continue
            if re.match(r"\s*[-+~]\s", l) and not re.match(r"\s*[-+~]\s*(\w+ \{|resource \")", l):
                other.append(l.strip())
        other = [o for o in other if "(known after apply)" not in o or not o.startswith("~")]
        if other:
            explain.append(f"{addr}: other changed lines ({len(other)}): " + " || ".join(other[:12]))
        ka = [l.strip() for l in body if "(known after apply)" in l and l.strip().startswith("~")]
        if ka:
            noise.append(f"{addr}: {len(ka)} '(known after apply)' attribute(s) -- provider fills them; confirm none is an identifier/ARN others depend on")
    if prev is not None:
        def body(ls):   # plan body only: first resource header .. Plan line (init's "- Installing ..." lines excluded)
            st = next((i for i, l in enumerate(ls) if re.match(r"\s*# \S+ (will be|must be)", l)), len(ls))
            return [l.strip() for l in ls[st:] if re.match(r"\s*[#~+-]|\s*Plan:", l)]
        a, b = body(lines), body(prev)
        noise.append("vs previous plan: IDENTICAL" if a == b else f"vs previous plan: DIFFERS ({len(set(a) ^ set(b))} changed lines) -- review the difference")
    return blockers, explain, noise


def first_plan(lines):
    """Only the FIRST plan in a task log: an Octopus apply step re-plans and prints a second one."""
    end = next((i for i, l in enumerate(lines) if re.match(r"\s*(Plan: \d+ to add|No changes\.)", l)), None)
    return lines if end is None else lines[:end + 1]


if __name__ == "__main__":
    cur = first_plan(load(sys.argv[1])); prev = first_plan(load(sys.argv[2])) if len(sys.argv) > 2 else None
    r = review(cur, prev)
    if r is None:
        print("NO PLAN FOUND in the input (no 'Plan:' / 'No changes.' line). Not reviewable -- do not recommend approval."); sys.exit(2)
    blockers, explain, noise = r
    print("BLOCKERS:" if blockers else "BLOCKERS: none"); [print("  !", b) for b in blockers]
    print("TO EXPLAIN (each needs a stated reason before you recommend approval):"); [print("  -", e) for e in explain]
    print("NOISE FILTERED:"); [print("  .", n) for n in noise] or print("  .", "none")
