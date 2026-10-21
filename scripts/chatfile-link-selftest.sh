#!/usr/bin/env bash
# Self-test for lib-chatfile-link.sh's per-session link separation (<harnessEpicKey>).
# HOME is repointed at a throwaway tree, so .session-chatfiles and the cwd both live there.
set -uo pipefail

REAL_HOME="$HOME"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T"
mkdir -p "$HOME/.claude/.session-chatfiles"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
no()  { fail=$((fail+1)); printf 'FAIL  %s (%s)\n' "$1" "$2"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || no "$1" "got '$2' want '$3'"; }

. "$REAL_HOME/Repos/AMA_APP/ama-claude-harness/hooks/lib-chatfile-link.sh"

# Central dir is resolved from the harness repo; stub it so nothing lands in Chat files/.
CENTRAL="$T/central"; mkdir -p "$CENTRAL"
chatfile_central_dir() { printf '%s' "$CENTRAL"; }

CWD="$T/proj"; mkdir -p "$CWD/Local Chat Files"
BASE="Shared Topic Chat.md"
LINKDIR="$CWD/Local Chat Files"
SID_A="aaaaaaaa-1111-2222-3333-444444444444"
SID_B="bbbbbbbb-1111-2222-3333-444444444444"

# --- session A gets the canonical name, nobody else owns it ---------------------------
touch "$CENTRAL/$BASE"
chatfile_symlink "$CENTRAL/$BASE" "$LINKDIR/$BASE"
printf '%s' "$LINKDIR/$BASE" > "$HOME/.claude/.session-chatfiles/$SID_A"

# --- session B arrives with the same name ---------------------------------------------
gotB="$(chatfile_ensure_link "$LINKDIR/$BASE" "$SID_B")"
eq "B does not get A's link" "$gotB" "$LINKDIR/Shared Topic ($SID_B) Chat.md"
[ -L "$gotB" ] && ok "B's link exists" || no "B's link exists" "missing"
eq "B points at B's own central file" "$(readlink "$gotB")" "$CENTRAL/Shared Topic ($SID_B) Chat.md"

# THE regression that mattered: A's link must survive B's arrival.
[ -L "$LINKDIR/$BASE" ] && ok "A's link is untouched" || no "A's link is untouched" "deleted"
eq "A's link still points at A's file" "$(readlink "$LINKDIR/$BASE")" "$CENTRAL/$BASE"

# --- B runs again: must REUSE its file, not mint another ------------------------------
printf '%s' "$gotB" > "$HOME/.claude/.session-chatfiles/$SID_B"
touch "$CENTRAL/Shared Topic ($SID_B) Chat.md"
gotB2="$(chatfile_ensure_link "$gotB" "$SID_B")"
eq "B is stable across a second call" "$gotB2" "$gotB"
n_central="$(find "$CENTRAL" -name "Shared Topic (*" | wc -l | tr -d ' ')"
eq "B minted exactly one central file" "$n_central" "1"

# --- A itself is unaffected by the new branch -----------------------------------------
gotA="$(chatfile_ensure_link "$LINKDIR/$BASE" "$SID_A")"
eq "A keeps the canonical path" "$gotA" "$LINKDIR/$BASE"

# --- a third session still separates --------------------------------------------------
SID_C="cccccccc-1111-2222-3333-444444444444"
gotC="$(chatfile_ensure_link "$LINKDIR/$BASE" "$SID_C")"
eq "C separates too" "$gotC" "$LINKDIR/Shared Topic ($SID_C) Chat.md"
[ "$gotC" != "$gotB" ] && ok "B and C do not collide" || no "B and C do not collide" "same path"

# --- own_central suffix is not nested on an already-suffixed base ---------------------
eq "own_central does not nest suffixes" \
   "$(chatfile_own_central "Shared Topic ($SID_B) Chat.md" "$SID_B" "$CENTRAL")" \
   "$CENTRAL/Shared Topic ($SID_B) Chat.md"

# --- relink_renamed onto a name another session holds (harness-gaps 2026-10-12) ---------
# D is on its fallback name; renaming to A's held topic must take D's own suffix, leave A's
# link alone, and print the path it linked (rename-topic persists that).
SID_D="dddddddd-1111-2222-3333-444444444444"
SD="${SID_D%%-*}"
touch "$CENTRAL/$SD Chat.md"; chatfile_symlink "$CENTRAL/$SD Chat.md" "$LINKDIR/$SD Chat.md"
printf '%s' "$LINKDIR/$SD Chat.md" > "$HOME/.claude/.session-chatfiles/$SID_D"
gotD="$(chatfile_relink_renamed "$LINKDIR/$SD Chat.md" "$LINKDIR/$BASE" "$SD")"
eq "D rename onto held name prints own suffixed path" "$gotD" "$LINKDIR/Shared Topic ($SD) Chat.md"
[ -L "$gotD" ] && ok "D's suffixed link exists" || no "D's suffixed link exists" "missing"
eq "A's link survives D's rename" "$(readlink "$LINKDIR/$BASE")" "$CENTRAL/$BASE"
# Same rename again (old pre-fix loop): must reuse D's file, never mint "(dddddddd-2)".
printf '%s' "$gotD" > "$HOME/.claude/.session-chatfiles/$SID_D"
gotD2="$(chatfile_relink_renamed "$gotD" "$LINKDIR/$BASE" "$SD")"
eq "D's repeat rename is a no-op" "$gotD2" "$gotD"
[ ! -e "$CENTRAL/Shared Topic ($SD-2) Chat.md" ] && ok "no (sid8-2) minted" || no "no (sid8-2) minted" "minted"
# Plain-file session E renaming onto A's link must not overwrite it with a regular file.
SID_E="eeeeeeee-1111-2222-3333-444444444444"; SE="${SID_E%%-*}"
printf 'x\n' > "$LINKDIR/$SE Chat.md"
printf '%s' "$LINKDIR/$SE Chat.md" > "$HOME/.claude/.session-chatfiles/$SID_E"
chatfile_relink_renamed "$LINKDIR/$SE Chat.md" "$LINKDIR/$BASE" "$SE" >/dev/null
[ -L "$LINKDIR/$BASE" ] && ok "plain-file rename leaves A's link a link" || no "plain-file rename leaves A's link a link" "clobbered"

# --- sync_session_name treats our own suffix as the same name --------------------------
. "$REAL_HOME/Repos/AMA_APP/ama-claude-harness/hooks/lib-fallback-rename.sh"
resolve_cc_name() { printf 'Shared Topic'; }
mkdir -p "$HOME/.claude/hooks"
printf '#!/usr/bin/env bash\ntouch "%s/renamed"\n' "$T" > "$HOME/.claude/hooks/rename-topic.sh"
printf 'x\n' >> "$gotD"
sync_session_name "$SID_D" "$gotD" "$CWD" "/dev/null"
[ ! -e "$T/renamed" ] && ok "own-suffixed name does not re-rename" || no "own-suffixed name does not re-rename" "rename-topic ran"
printf 'x\n' > "$LINKDIR/Other ($SD-x) Chat.md"
sync_session_name "$SID_D" "$LINKDIR/Other ($SD-x) Chat.md" "$CWD" "/dev/null"
[ -e "$T/renamed" ] && ok "a genuinely different name still renames" || no "a genuinely different name still renames" "no rename"

printf '\nRESULT: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
