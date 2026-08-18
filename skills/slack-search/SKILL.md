---
name: slack-search
description: Gotcha confirmed the hard way -- slack_search_channels silently omits private channels unless you ask for them. Use whenever a channel search comes back empty/wrong and the channel might be private.
---

# Slack channel search

**`slack_search_channels` defaults to `channel_types: public_channel` only --
private channels are silently omitted, no warning, "no results found" reads exactly
like "channel doesn't exist."**

**Always pass `channel_types: "public_channel,private_channel"` on a Slack channel
search, every time** -- don't rely on the default, and don't conclude a channel
doesn't exist off a default-only search. If it still comes back empty with both
types included, THEN it's a genuine miss (wrong name, archived, or the bot/user
token genuinely isn't a member of that private channel).
