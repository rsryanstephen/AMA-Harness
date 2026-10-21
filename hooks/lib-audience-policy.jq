# Resolves the outbound-communication policy for a set of addressees.
# Input: harness-config.json on stdin.  --arg keys: newline-separated match keys
# (email addresses, Slack user ids, or bare names), already CR-stripped by the caller.
# Output: one prose line for injection, or "" when no configured person matched.
#
# Kept as a .jq file rather than inline in the shell: the program contains ", $, (, ) and
# newlines, and every attempt to carry it inside a shell string in this repo mangled an escape
# sequence at least once. A file has exactly one reading.
(.audiences // {}) as $a
| ($a.people // []) as $ppl
| ($a.defaultLevel // "business") as $dflt
| ($keys | ascii_downcase | split("\n") | map(select(length > 0))) as $k
| [ $ppl[]
    | (((.emails // []) + (.slackUserIds // []) + [.name]) | map(ascii_downcase)) as $ids
    | select(any($ids[]; . as $i | $k | index($i) != null))
  ] as $hit
| if ($hit | length) == 0 then "" else
    # MIN level wins: one business-level addressee puts the whole message at business level.
    (if any($hit[]; (.level // $dflt) == "business") then "business" else "<level>" end) as $lvl
  | ([$hit[] | .avoid // []] | flatten | unique) as $avoid
  | "AUDIENCE POLICY (standing user rule; the people/role data is harness-config.json .audiences -- see memory/audience-communication-levels.md). Addressee(s) recognised: "
    + ([$hit[] | .name] | join(", "))
    + ". Resolved level: " + ($lvl | ascii_upcase)
    + (if (any($hit[]; (.level // $dflt) == "business")
           and any($hit[]; (.level // $dflt) == "<level>"))
        then " -- a genuinely mixed audience, and the lowest level among the addressees wins"
        else "" end)
    + ". " + (if $lvl == "business"
        then "Write it business-level: the decision, the impact, and what you need from them. Technical detail ONLY where it is genuinely unavoidable or they asked for it."
        else "Give a <level> basis for your statements, but say it in as few words as it can be said -- these people are short on time." end)
    + " Cut detail; keep it brief and to the point. This applies to Slack exactly as it does to email."
    + (if ($avoid | length) > 0 then " Do NOT include: " + ($avoid | join("; ")) + "." else "" end)
    + " Per person: " + ([$hit[] | select((.notes // "") != "") | .name + " -- " + .notes] | join(" | "))
    + "."
  end
