#!/usr/bin/env python
"""Flatten harness-config.json to scalar Octopus variables, and rebuild it from them.

The Octopus "Claude Harness" variable set used to hold the whole config as ONE JSON blob
(`HarnessConfigJson`). That made every value invisible and un-editable in the Octopus UI, and
unscopeable. This module is the two directions of the replacement: the set now holds one
variable per scalar leaf, named `HarnessConfig:<colon-separated path>`.

Colon, not dot, is the separator -- deliberately. `releaseNotes.greetingNames` is keyed BY
EMAIL ADDRESS, and those keys contain dots, so a dotted path is ambiguous. Colons are idiomatic
in Octopus variable naming and were verified empirically to survive a PUT/GET round trip
verbatim before this scheme was built.

THE SHAPE COMES FROM THE TRACKED EXAMPLE, NOT FROM OCTOPUS. `harness-config.example.json` is in
git and already carries the full key skeleton, so it is the schema: it says which leaves are
numbers, which nodes are arrays, and what an array element looks like. Octopus therefore only
has to carry values, and no type information has to be smuggled into variable names. It also
means a fresh clone can still rebuild a valid config when the org store is missing a key.

Three node kinds, resolved against the example:
  * array          -- a numeric path segment is an index; element 0 is the template
  * data-keyed map -- an object whose ONLY key is not a plain identifier (the example carries
                      one placeholder entry, e.g. "first.recipient@example.com"); any key is
                      allowed and that entry is the template. Same heuristic
                      config-key-parity-reminder.sh already uses to tell a map ENTRY from a key.
  * plain object    -- keys must match the example exactly. A live key the example lacks is an
                      ERROR, not a wildcard: the org store would carry a value that a fetch
                      could never place, so it would vanish silently on the next machine.

Usage:
  harness-config-vars.py flatten <config.json> <example.json> [--prefix P]
      -> stdout: JSON array of {"Name","Value"}; exit 3 on an unplaceable key
  harness-config-vars.py unflatten <vars.json> <example.json> [--prefix P]
      -> stdout: the rebuilt config JSON; warnings about missing keys on stderr
         <vars.json> is an Octopus variable-set document (has a "Variables" array) or a plain
         {"Name":...,"Value":...} list.
"""

import json
import io
import sys
import re
import collections

DEFAULT_PREFIX = "HarnessConfig"
PLAIN_IDENT = re.compile(r"^[A-Za-z][A-Za-z0-9]*$")


def is_data_keyed_map(node):
    """An example object that stands for 'any key' rather than these exact keys."""
    return (isinstance(node, dict) and len(node) == 1
            and not PLAIN_IDENT.match(list(node.keys())[0]))


def template_for(node, segment):
    """Descend one segment of the example. Returns (subnode, ok)."""
    if isinstance(node, list):
        # numeric segment -> array index; element 0 is the shape of every element
        if not node:
            return None, False
        return node[0], True
    if isinstance(node, dict):
        if segment in node:
            return node[segment], True
        if is_data_keyed_map(node):
            return list(node.values())[0], True
        return None, False
    return None, False


def resolve(example, path):
    """Walk the example along path. Returns (leaf_template, ok)."""
    node = example
    for seg in path:
        node, ok = template_for(node, seg)
        if not ok:
            return None, False
    return node, True


def flatten(cfg, example, prefix):
    out = []
    errors = []

    def walk(node, path):
        if isinstance(node, dict):
            for k, v in node.items():
                walk(v, path + [k])
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, path + [str(i)])
        else:
            tmpl, ok = resolve(example, path)
            if not ok or isinstance(tmpl, (dict, list)):
                errors.append(":".join(path))
                return
            if node is None:
                # null has no scalar representation that survives a round trip; the example
                # has no nulls, so treat it as a config error rather than inventing an encoding.
                errors.append(":".join(path) + " (null)")
                return
            if isinstance(node, bool):
                val = "true" if node else "false"
            else:
                val = str(node)
            out.append({"Name": prefix + ":" + ":".join(path), "Value": val})

    walk(cfg, [])
    return out, errors


def coerce(raw, tmpl, where, warnings):
    """Convert an Octopus string back to the type the example says this leaf is.

    Never guesses from the value's shape: a digits-only version string or account id must stay
    a string. The example is the only authority.
    """
    if isinstance(tmpl, bool):
        return raw.strip().lower() == "true"
    if isinstance(tmpl, int):
        try:
            return int(raw)
        except ValueError:
            warnings.append("%s: expected a number, got %r -- kept as a string" % (where, raw))
            return raw
    if isinstance(tmpl, float):
        try:
            return float(raw)
        except ValueError:
            warnings.append("%s: expected a number, got %r -- kept as a string" % (where, raw))
            return raw
    return raw


def skeleton(example):
    """Example structure with scalars removed: containers only, arrays emptied.

    This is what preserves an EMPTY array (7 of them in the real config) -- an empty array
    contributes no variables at all, so without the skeleton it would come back as a missing
    key instead of []. It also fixes key order to the example's, which keeps diffs small.
    """
    if isinstance(example, dict):
        if is_data_keyed_map(example):
            return collections.OrderedDict()
        return collections.OrderedDict((k, skeleton(v)) for k, v in example.items())
    if isinstance(example, list):
        return []
    return None  # scalar placeholder, filled from variables or defaulted


def place(root, path, value, example=None):
    """Set path to value, creating intermediate containers from the EXAMPLE's shape.

    Seeding a new container with skeleton(template) rather than an empty dict is what keeps an
    array ELEMENT faithful: several `audiences.people` entries have `avoid: []`, and an empty
    array contributes no variables, so a bare dict here would silently drop those keys from the
    rebuilt config. It also fixes each element's key order to the example's.
    """
    node = root
    for i, seg in enumerate(path):
        last = (i == len(path) - 1)
        if isinstance(node, list):
            idx = int(seg)
            while len(node) <= idx:
                node.append(None)
            if last:
                node[idx] = value
            else:
                if node[idx] is None:
                    tmpl, ok = resolve(example, path[:i + 1]) if example is not None else (None, False)
                    node[idx] = skeleton(tmpl) if ok and isinstance(tmpl, (dict, list)) \
                        else collections.OrderedDict()
                node = node[idx]
        else:
            if last:
                node[seg] = value
            else:
                if node.get(seg) is None:
                    tmpl, ok = resolve(example, path[:i + 1]) if example is not None else (None, False)
                    node[seg] = skeleton(tmpl) if ok and isinstance(tmpl, (dict, list)) \
                        else collections.OrderedDict()
                node = node[seg]


def prune(node):
    """Drop scalar leaves nothing filled in, and array holes."""
    if isinstance(node, dict):
        for k in list(node.keys()):
            v = node[k]
            if v is None:
                del node[k]
            else:
                prune(v)
    elif isinstance(node, list):
        while None in node:
            node.remove(None)
        for v in node:
            prune(v)


def unflatten(variables, example, prefix):
    warnings = []
    root = skeleton(example)
    seen = set()

    for var in variables:
        name = var.get("Name") or ""
        if not name.startswith(prefix + ":"):
            continue
        path = name[len(prefix) + 1:].split(":")
        if path[:1] == ["user"]:
            warnings.append("%s: the org store must not carry a user identity -- skipped" % name)
            continue
        tmpl, ok = resolve(example, path)
        if not ok or isinstance(tmpl, (dict, list)):
            warnings.append("%s: no counterpart in the example config -- skipped, the "
                            "example is the schema and must gain this key first" % name)
            continue
        place(root, path, coerce(var.get("Value") or "", tmpl, name, warnings), example)
        seen.add(":".join(path))

    # An example scalar with no variable behind it: fall back to the example's own value and say
    # so. This is the fresh-org bootstrap path -- a clean clone must still produce a config that
    # parses, with placeholders visible rather than keys silently absent.
    def fill_defaults(ex, path):
        # `user` is per-person identity and is deliberately absent from the org store
        # (flatten strips it). Rebuilding it from the example would hand every machine
        # the placeholder identity and, worse, make a fetch look like it had supplied
        # one. The caller merges the local user block instead.
        if path == ["user"]:
            return
        if isinstance(ex, dict):
            if is_data_keyed_map(ex):
                return
            for k, v in ex.items():
                fill_defaults(v, path + [k])
        elif isinstance(ex, list):
            return  # array contents come only from variables
        else:
            key = ":".join(path)
            if key not in seen:
                warnings.append("%s: not in the variable set -- using the example's value" % key)
                place(root, path, ex, example)

    fill_defaults(example, [])
    prune(root)
    # The skeleton still carries an empty `user` container. Drop it: the org store never holds
    # an identity, so the rebuilt config must not claim one either -- the caller merges the
    # local user block (or leaves harness-setup to ask).
    root.pop("user", None)
    return root, warnings


def main(argv):
    # Force UTF-8 on both streams. Python's stdout defaults to the Windows ANSI codepage here,
    # which silently rewrote an em-dash in a `notes` value into a byte the next json.load
    # rejected -- confirmed live. Same class of hazard as the "payloads travel via temp FILES
    # only" rule in octopus-config-sync.sh's header: on this platform, config text must never
    # cross a boundary that has not been pinned to UTF-8.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except AttributeError:
            pass

    if len(argv) < 4:
        sys.stderr.write(__doc__)
        return 2
    mode, a, b = argv[1], argv[2], argv[3]
    prefix = DEFAULT_PREFIX
    if "--prefix" in argv:
        prefix = argv[argv.index("--prefix") + 1]

    example = json.load(io.open(b, encoding="utf-8"),
                        object_pairs_hook=collections.OrderedDict)

    if mode == "flatten":
        cfg = json.load(io.open(a, encoding="utf-8"),
                        object_pairs_hook=collections.OrderedDict)
        cfg.pop("user", None)   # per-person identity is never pushed
        out, errors = flatten(cfg, example, prefix)
        if errors:
            sys.stderr.write(
                "Refusing to push: %d config key(s) have no counterpart in\n  %s\n"
                "The example config IS the schema -- a value pushed under a key the example\n"
                "lacks could never be placed by a fetch, so it would vanish silently on the\n"
                "next machine. Add the key (with a placeholder value) to the example first:\n%s\n"
                % (len(errors), b, "".join("  - " + e + "\n" for e in errors)))
            return 3
        sys.stdout.write(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
        return 0

    if mode == "unflatten":
        doc = json.load(io.open(a, encoding="utf-8"),
                        object_pairs_hook=collections.OrderedDict)
        variables = doc["Variables"] if isinstance(doc, dict) else doc
        cfg, warnings = unflatten(variables, example, prefix)
        for w in warnings:
            sys.stderr.write("  note: " + w + "\n")
        sys.stdout.write(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
        return 0

    sys.stderr.write("unknown mode: %s\n" % mode)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
