# Finds which configured people a free-text blob NAMES.
# Input: harness-config.json on stdin.  --arg text: the prompt / message text.
# Output: one lowercased match key per line (the person's name), or nothing.
#
# An email address or Slack user id is distinctive enough for a plain substring test. A bare
# first name is not -- unanchored, a short name matches inside ordinary words -- so names are
# word-boundary matched, and names shorter than three characters are ignored entirely. The
# name is stripped to plain name characters before it goes into the pattern, so a config entry
# can never inject a regex metacharacter.
# Hyphen is NOT a boundary: a name inside a kebab identifier (memory slug clientcorp-cc-horia,
# a branch/file name) is a reference to a thing, not an addressee -- false-positived 2026-08-31.
($text | ascii_downcase) as $t
| (.audiences.people // [])[]
| (((.emails // []) + (.slackUserIds // [])) | map(ascii_downcase)) as $ids
| (.name // "" | ascii_downcase) as $nm
| if any($ids[]; . as $i | $t | contains($i)) then $nm
  elif ($nm | length) >= 3
       and ($t | test("(^|[^a-z0-9-])" + ($nm | gsub("[^a-z0-9 -]"; "")) + "([^a-z0-9-]|$)"))
    then $nm
  else empty end
