#!/usr/bin/env perl
# Renders ~/.claude/sessions.txt into ~/.claude/sessions.md, AND computes the
# context-size column it needs -- one process, in-memory, single write at the end.
#
# Used to be two pieces: this file only sized contexts, and render-sessions-md.sh did
# the actual rendering in a bash loop forking ~8-10 subprocesses PER ROW (command
# substitutions, `printf|grep -oP` pipelines, slug()'s 4-stage pipe). Measured on a real
# 65-row sessions.txt: 43s. Every automatic caller of that render (on-stop.sh's Stop
# hook: 10s budget, on-session-end.sh's SessionEnd hook: 5s budget) got killed mid-loop
# every single time -- confirmed via a frozen `sessions.md.tmp` found on disk, 12 of 65
# rows, matching a ~10s kill. Only the two model-invoked callers (rename-topic.sh,
# relocate-session.sh, no hook timeout) ever let it finish. Net effect: sessions.md
# lagged sessions.txt by however long since the last on-prompt.sh render actually landed
# inside its 60s budget -- sometimes tens of seconds, sometimes never. One perl process
# doing the same work: ~1s (measured), comfortably inside every caller's budget.
#
# Context size = last NONZERO "usage":{...} blob in the transcript, fields summed
# (input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens)
# -- that sum is the live context window size at the point of the last turn.
# Post-compaction transcripts already reflect the reset in their last usage blob, so no
# special-casing needed for that. A turn that errors out (API 529 etc) writes a
# synthetic ALL-ZERO usage blob though -- taking the textually-last blob unconditionally
# would clobber a real nonzero value from the last successful turn with that zero, e.g.
# a real session (26b03ad8) that had 4 real turns then died on a 529 storm, its last
# blob all-zero, would render as "0" in the brightest green on the color ramp -- reading
# as a healthy fresh session instead of a dead one. So this walks backwards and takes
# the last NONZERO blob; deliberately does NOT switch to MAX across the whole
# transcript -- /compact resets context, so a later smaller number is the correct live
# state, not a decrease to paper over. Only genuinely no nonzero blob at all -> '-'.
#
# Only seeks the last 300KB of each file (never loads a full 89MB transcript) --
# but a single JSONL line can exceed that (base64 screenshots from ama-ui-verify,
# large file reads), so if the tail window has no match, falls back to a WIDER but still
# BOUNDED 3MB window for that one file (not the full file size -- a long 529 storm can
# fill 300KB with nothing but zero blobs, ~5KB apart each, so "no nonzero in the tail"
# is reachable on a real multi-MB transcript, unlike the old "no blob at all" condition
# which only tiny files ever hit; this corpus has a 91MB transcript, slurping that whole
# file inside a 5s SessionEnd hook budget is not acceptable). 3MB covers roughly 600
# consecutive errored turns, far past any plausible storm, and fully covers anything
# already under 3MB so existing small-file behavior is unchanged.
#
# Anchors on "usage":{ first, then pulls each of the 4 fields BY NAME out of a bounded
# slice -- the blob also nests "iterations":[{...}] with the same field names in a
# DIFFERENT order, so an unanchored/order-dependent scan would misread those instead.
use strict;
use warnings;

my $HOME = $ENV{HOME};
my $SESS = "$HOME/.claude/sessions.txt";
my $OUT = "$HOME/.claude/sessions.md";

# Rows under this many tokens are hidden from sessions.md (display-only -- sessions.txt
# keeps every line). Small sessions did little worth returning to and crowd out the
# long-running ones the list exists to surface. Compared against the RAW token sum, not
# the rounded "Nk" display field.
my $MIN_CTX = 90_000;

# ...but only for a session whose TRANSCRIPT is also small. `/compact` resets the context
# window, so live context stopped being a proxy for "did little work" the moment it was
# used as one: 8c362fae is 13.9 MB / 8103 lines / 1742 turns and sat at 79.6k live, hidden
# from the very list that exists to surface long-running sessions (found the hard way -- the
# user could only locate it by grepping sessions.txt). Measured on the whole hidden bucket,
# the two populations don't overlap: the wrongly-hidden pair are 13.9 MB and 8.4 MB, the 9
# genuinely trivial ones are all under 360 KB. Size rather than turn count because `-s` is
# free while counting `"usage":{` anchors means reading whole multi-MB files, against a
# renderer whose entire design is a bounded 300 KB tail per transcript.
my $MIN_BYTES = 1_000_000;

exit 0 unless -f $SESS;

# ---- context-size map: one sid -> tokens (or "-" if transcript exists, no usage yet) ----
# Every transcript this loop finds gets an entry (real number or "-"). A sid with NO
# entry at all means "no transcript file on this machine" -- that's the hide signal
# below. Since this whole script either writes sessions.md once at the end or not at
# all (see the hash-guard near the bottom), that hide signal is always trustworthy here
# -- unlike the old two-process split, there's no "perl died partway" case that could
# make sessions.md hide a live session by mistake.
my @files = `find "$HOME/.claude/projects" -name '*.jsonl' -not -path '*/subagents/*' 2>/dev/null`;
chomp @files;

my %CTX;
my %TRPATH;
my %SIZE;   # sid -> transcript bytes; the "did real work" signal the small-row filter needs
# Name census, harvested from the SAME tail buffer this loop already reads for the
# context size -- no extra I/O.
#   %NAMECOUNT name -> how many distinct sessions answer to that name; decides whether a
#                      name is safe to print as a resume target
#   %CURNAME   sid  -> its current name, whatever the source (customTitle, else agentName,
#                      else aiTitle) -- the LAST-RESORT display for a row that has no
#                      harness topic at all
#   %SIDNAMES  sid  -> set of names already counted for that sid (dedupe, since one
#                      session's customTitle/agentName are usually the same string)
my (%NAMECOUNT, %CURNAME, %SIDNAMES, %LASTTS);
for my $f (@files) {
  next unless -f $f;
  my ($sid) = $f =~ m{([^/\\]+)\.jsonl$};
  next unless $sid;
  $TRPATH{$sid} = $f;
  my $size = -s $f;
  $SIZE{$sid} = $size;
  my $buf = read_tail($f, $size, 300_000);
  my $nz = defined $buf ? usage_sum($buf) : undef;
  unless (defined $nz) {
    my $wider = read_tail($f, $size, 3_000_000); # bounded fallback, not $size
    if (defined $wider) { $buf = $wider; $nz = usage_sum($wider); }
  }
  $CTX{$sid} = defined $nz ? $nz : '-';
  harvest_names($sid, $buf) if defined $buf;
  # Last activity for the newest-wins hide -- NOT mtime: bulk touches (10-08 14:35,
  # 10-16 02:15) tie dozens of transcripts, and a rename append bumps it.
  $LASTTS{$sid} = last_typed_ts($buf) if defined $buf;
}

# Timestamp of the last prompt the USER typed -- a background-task notice, slash-command
# echo or tool result landing in an old continuation is not the user working there (69dd3393's
# last entries, 10-23 08:44, were task notifications). Falls back to any timestamp when the
# window holds no typed prompt. Same rule as scripts/session-name-dedupe.pl's, keep in step.
sub last_typed_ts {
  my ($buf) = @_;
  my $typed;
  for my $l (split /\n/, $buf) {
    next unless index($l, '"type":"user"') >= 0 && $l =~ /"content":"(?!<(?:task-notification|local-command|command-name|system-reminder))/;
    next if $l =~ /"isMeta":true/;
    $typed = $1 if $l =~ /"timestamp":"([^"]+)"/;
  }
  return $typed // (sort($buf =~ /"timestamp":"([^"]+)"/g))[-1];
}

# Records a session's names from its tail buffer. Only the LATEST value of each field is
# taken: a superseded auto-title isn't what the session answers to any more, and counting
# it would force perfectly good rows onto a raw sid for a collision that no longer exists.
# All three fields are counted, not just the two the harness uses as handles -- Claude
# Code's own resume picker matched a session carrying ONLY an aiTitle (30a58b66), so an
# aiTitle the harness would never print can still make someone else's handle ambiguous.
sub harvest_names {
  my ($sid, $buf) = @_;
  my %last;
  while ($buf =~ /"(customTitle|agentName|aiTitle)":"([^"]*)"/g) { $last{$1} = $2; }
  count_name($sid, $last{$_}) for qw(customTitle agentName aiTitle);
  my $cur = $last{customTitle} // $last{agentName} // $last{aiTitle};
  $CURNAME{$sid} = $cur if defined $cur && length $cur;
}

# The small-row test, in ONE place: the handle pre-pass and the render loop both gate on
# it, and a drift between the two would let a row render with no handle resolved.
# Raw token sum, not the rounded "Nk" display field. See $MIN_BYTES for why size is the
# second clause rather than context alone.
sub row_is_small {
  my ($sid) = @_;
  return 0 unless defined $sid && exists $CTX{$sid} && $CTX{$sid} ne '-';
  return $CTX{$sid} < $MIN_CTX && ($SIZE{$sid} // 0) < $MIN_BYTES;
}

sub count_name {
  my ($sid, $name) = @_;
  return unless defined $name && length $name;
  return if $SIDNAMES{$sid}{$name}++;
  $NAMECOUNT{$name}++;
}

# Reads the last $window bytes of $file. Split out from the token-summing below so the
# ONE read per transcript feeds both the context size and the name census -- the census
# was free to add precisely because this buffer already existed.
sub read_tail {
  my ($file, $size, $window) = @_;
  my $off = $size > $window ? $size - $window : 0;
  open my $fh, '<:raw', $file or return undef;
  seek $fh, $off, 0;
  local $/;
  my $buf = <$fh>;
  close $fh;
  return $buf;
}

# Returns the summed token count from the LAST NONZERO "usage":{...} blob in $buf
# (walking anchors backwards), or undef if every blob is zero or there's no blob at all --
# caller can't tell those two apart and doesn't need to, both mean "nothing to show".
sub usage_sum {
  my ($buf) = @_;
  return undef unless defined $buf;

  # Walk "usage":{ anchors backwards, take a fixed-length slice after each -- a
  # brace-balanced (non-greedy \{...\}) capture is unreliable here because the blob
  # nests "server_tool_use":{...} and "iterations":[{...}] objects, so the nearest
  # closing "}" can land well before all 4 top-level fields. The 4 top-level fields
  # always appear TEXTUALLY BEFORE any nested object (confirmed against a real
  # transcript line), so a fixed 600-char slice plus "first match wins" per field name
  # is reliable regardless of field order.
  my $pos = length($buf);
  while ((my $anchor = rindex($buf, '"usage":{', $pos - 1)) >= 0) {
    my $slice = substr($buf, $anchor, 600);

    my ($i) = $slice =~ /"input_tokens":(\d+)/;
    my ($cc) = $slice =~ /"cache_creation_input_tokens":(\d+)/;
    my ($cr) = $slice =~ /"cache_read_input_tokens":(\d+)/;
    my ($o) = $slice =~ /"output_tokens":(\d+)/;

    if (defined $i || defined $cr) { # need at least a core field
      my $sum = ($i // 0) + ($cc // 0) + ($cr // 0) + ($o // 0);
      return $sum if $sum > 0;
    }
    $pos = $anchor; # keep walking backwards past this (zero or unparseable) blob
  }
  return undef;
}

# ---- read sessions.txt, snapshot it for the hash-guard near the bottom ----
open my $sfh, '<', $SESS or exit 0;
my @lines = <$sfh>;
close $sfh;
chomp @lines;
my $orig_snapshot = join("\n", @lines);

# "<N>k" (rounded) once >=1000, else the raw number.
sub humanize_ctx {
  my ($n) = @_;
  return $n if $n < 1000;
  return sprintf('%dk', int(($n + 500) / 1000));
}

# Green->yellow->orange->red spectrum, absolute tokens 0->600k (capped red past that) --
# NOT %-of-window, see render's own git history for why. 25 stops, 25k-token buckets.
my @CTX_COLORS = (
  "#1dc91d", "#2fc91d", "#41c91d", "#52c91d", "#64c91d", "#76c91d", "#87c91d", "#97c91d",
  "#a8c91d", "#b8c91d", "#c9c91d", "#c9ba1d", "#c9ac1d", "#c99e1d", "#c98f1d", "#c9811d",
  "#c9731d", "#c9681d", "#c95d1d", "#c9521d", "#c9481d", "#c93d1d", "#c9321d", "#c9271d",
  "#c91d1d",
);

# Resume-handle: the LATEST customTitle, else the LATEST agentName, read directly from
# the transcript -- NOT the .explicitname snapshot (only refreshed by on-stop.sh when
# that session completes a turn, so it goes stale the moment a session is /rename'd and
# then goes quiet -- confirmed real: a session's printed `claude -r "<name>"` command
# stopped working because .explicitname was frozen on an EVEN OLDER customTitle than the
# session's actual current one). aiTitle is deliberately never used here -- Claude Code's
# own `--resume <name>` doesn't recognize an AI title, only an explicit customTitle or
# plan-accept's agentName (same distinction lib-fallback-rename.sh's resolve_cc_name
# documents). Bounded-tail read (last ~4MB; title lines are appended every few turns, so
# the tail hits almost always), full-file fallback only if the tail has nothing --
# mirrors resolve_cc_name's own approach and cost rationale.
sub resume_handle {
  my ($tr_path) = @_;
  return '' unless defined $tr_path && length $tr_path && -f $tr_path;
  my $size = -s $tr_path;
  my $hits = scan_titles($tr_path, $size, 4_000_000);
  $hits = scan_titles($tr_path, $size, $size) unless @$hits; # full-file fallback
  my ($last_custom) = grep { $_->[0] eq 'customTitle' } reverse @$hits;
  return ($last_custom->[1], 'customTitle') if $last_custom;
  my ($last_agent) = grep { $_->[0] eq 'agentName' } reverse @$hits;
  return ($last_agent->[1], 'agentName') if $last_agent;
  return ('', '');
}

# Kebab-slug, matching how the harness names a chat file from a session name. Used only
# to ask "are these two strings the same name?" -- so that a customTitle differing from
# sessions.txt field 1 by punctuation/case alone isn't mistaken for a rename.
sub slugify {
  my ($s) = @_;
  $s = lc($s // '');
  $s =~ s/[^a-z0-9]+/-/g;
  $s =~ s/^-+|-+$//g;
  return $s;
}

# Returns [ [key, value], ... ] in file order, for customTitle/agentName occurrences in
# the last $window bytes of $file.
sub scan_titles {
  my ($file, $size, $window) = @_;
  my $off = $size > $window ? $size - $window : 0;
  open my $fh, '<:raw', $file or return [];
  seek $fh, $off, 0;
  local $/;
  my $buf = <$fh>;
  close $fh;
  return [] unless defined $buf;
  my @hits;
  while ($buf =~ /"(customTitle|agentName)":"([^"]*)"/g) {
    push @hits, [$1, $2];
  }
  return \@hits;
}

# Skip the --chrome append when chrome-by-default is already on (top-level
# claudeInChromeDefaultEnabled in ~/.claude.json, written by /chrome -> "Enabled by
# default" -- see harness-setup step 5b): redundant there, and worse than redundant --
# an explicit flag on every row would keep forcing Chrome on resumes even after the
# user turns the default back off. Regex read, not a JSON parse, matching this
# script's transcript handling; the key is Claude-Code-owned and top-level only.
my $chrome_default = 0;
if (open my $cj, '<', "$ENV{HOME}/.claude.json") {
  local $/; my $c = <$cj>; close $cj;
  $chrome_default = 1 if defined $c && $c =~ /"claudeInChromeDefaultEnabled"\s*:\s*true/;
}

# Pre-pass: resolve every RENDERED row's authoritative handle before rendering any of
# them, because whether a handle is safe to print depends on the other rows. resume_handle
# reads a 4 MB tail (full-file fallback), wider than the 300 KB the harvest above used, so
# a row's authoritative name can differ from what its own tail showed -- fold those in too.
# Only rows that will actually render are resolved: the hide filters below depend on %CTX
# alone, so applying them here costs nothing and avoids ~90 extra wide reads for rows
# nobody sees. Hidden sessions still count toward ambiguity through the harvest above,
# which covered every transcript on the machine.
my (%HANDLE, %RENAMED);
for my $line (@lines) {
  next unless length $line;
  my ($topic, $cmd) = split(/ /, $line, 2);
  next unless defined $topic && defined $cmd;
  my ($sid) = $cmd =~ /claude -r (\S+)/;
  next unless defined $sid && length $sid;
  next unless exists $CTX{$sid} && $CTX{$sid} ne '-' && !row_is_small($sid);
  my ($h, $kind) = resume_handle($TRPATH{$sid});
  next unless length $h;
  $HANDLE{$sid} = $h;
  count_name($sid, $h);
  # An EXPLICIT rename (`/rename`, the only thing that writes customTitle) that field 1
  # hasn't caught up with. Auto-titles deliberately don't qualify: agentName/aiTitle drift
  # on their own as a conversation moves, and letting that override field 1 would rewrite
  # ~67 rows' display names away from the harness topic -- which is also the chat file's
  # name -- for no user-visible reason.
  $RENAMED{$sid} = $h if $kind eq 'customTitle' && slugify($h) ne slugify($topic);
}

# Bold-field name for a row -- see the render loop's comment above its call for the cases.
sub display_name {
  my ($topic, $sid) = @_;
  my $display = $topic;
  if (defined $sid) {
    $display = $RENAMED{$sid} if defined $RENAMED{$sid};
    $display = $CURNAME{$sid}
      if $topic eq (split(/-/, $sid))[0] && defined $CURNAME{$sid} && length $CURNAME{$sid};
    # Claude Code itself suffixes " (N)" when a session continues into a new sid (/compact
    # here: c37804ee titled "Harness gaps (2)", successor of harness-gaps f4d6fe04) -- the
    # user never typed that name. Strip it so the pair collapses below. Only when the
    # session's own title carries the suffix: a bare "-24" can be a real name part.
    my $t = $HANDLE{$sid} // $CURNAME{$sid} // '';
    if ($t =~ /\s\((\d+)\)$/) { my $n = $1; $display =~ s/(?:\s\(\Q$n\E\)|-\Q$n\E)$//; }
    # session-name-dedupe.pl's marker is a GROUPING hint, not a hide verdict: show the base
    # name so the row joins its lineage and newest-wins below decides. A marked session the
    # user went back to must still surface (3072582c, marked superseded by its own /compact
    # continuation 69dd3393, then resumed and used past it). Taken from the handle, not
    # field 1 -- sessions.txt truncates topics (".../superseded-by-f650").
    $display = $1 if $t =~ /^(.*) - superseded by [0-9a-f]{8}$/;
  }
  return $display;
}

# One row per displayed name: the most recently active session wins, older ones hide.
# Same name on two rows = a successor, not a peer -- a context-exhausted session continued
# into a new sid (b1afbcc5 -> 99218d77), or a fork/rewind (eb4e80db / 76982b20, identical
# first prompt + timestamp). Never sub-agents: those get no resumable sid of their own.
# Display-only, like the other hides -- sessions.txt keeps every line.
my %NEWEST;   # slug(display) -> [last timestamp, sid]
for my $line (@lines) {
  next unless length $line;
  my ($topic, $cmd) = split(/ /, $line, 2);
  next unless defined $topic && defined $cmd;
  my ($sid) = $cmd =~ /claude -r (\S+)/;
  next unless defined $sid && exists $CTX{$sid} && $CTX{$sid} ne '-' && !row_is_small($sid);
  my $key = slugify(display_name($topic, $sid));
  my $mtime = $LASTTS{$sid} // "";
  $NEWEST{$key} = [$mtime, $sid] if !$NEWEST{$key} || $mtime gt $NEWEST{$key}[0];
}

my $out = "# Claude Code Sessions\n\n";
my $hidden = 0;
my $small = 0;
my $superseded = 0;
my %SHARED;   # names a rendered row shows or would have resumed by, that aren't unique

for my $line (@lines) {
  next unless length $line;
  my ($topic, $cmd) = split(/ /, $line, 2);
  next unless defined $topic && defined $cmd;

  my $sid;
  $sid = $1 if $cmd =~ /claude -r (\S+)/;

  # Hide rows with no transcript file at all, OR a transcript that never produced a
  # nonzero usage blob -- both are unresumable dead weight. The latter catches: a
  # session with zero turns at all (metadata-only, e.g. 49c9e96b), a session with
  # prompts but no assistant response ever landed (d6896aa7), and a session whose every
  # turn errored out (26b03ad8 -- API 529 storm, would otherwise render as a bright-
  # green "0", reading as fresh/healthy instead of dead). exists() without eq '-' would
  # still wrongly keep a transcript that resolved to '-' -- exists() only tests key
  # presence, not value truthiness.
  if (defined $sid && length $sid && (!exists $CTX{$sid} || $CTX{$sid} eq '-')) {
    $hidden++;
    next;
  }

  # Small sessions did little worth returning to and crowd out the long-running ones this
  # list exists to surface. Display-only, like the guard above: sessions.txt keeps the
  # line, so this is always resumable via `grep <name> sessions.txt`, unlike the
  # unresumable bucket.
  if (defined $sid && length $sid && row_is_small($sid)) {
    $small++;
    next;
  }

  if (defined $sid && length $sid) {
    my $n = $NEWEST{slugify(display_name($topic, $sid))};
    if ($n && $n->[1] ne $sid) { $superseded++; next; }
  }

  # A name is only an ADDRESS while exactly one session answers to it. Two sessions here
  # carried the title "Update latest meeting notes", and `claude -r "Update latest meeting
  # notes"` dropped the user into the resume PICKER instead of resuming -- a printed
  # command that silently doesn't do what it says. Falling back to the raw sid is what a
  # row with no resolvable name already does, so there's no new shape to learn.
  my $ename = (defined $sid && defined $HANDLE{$sid}) ? $HANDLE{$sid} : '';
  if (length $ename && ($NAMECOUNT{$ename} // 0) > 1) {
    # Record it for the footer: two identically-named rows are baffling on their own
    # (they were -- that's what prompted this), and the note is the only place the reader
    # learns that the raw sid in the command is deliberate rather than a rendering miss.
    $SHARED{$ename} = 1;
    $ename = '';
  }
  if (length $ename) {
    # No escaping needed here, unlike the old bash version: bash's ${var/pat/repl}
    # treats an unescaped & in the REPLACEMENT as "insert the whole match", so that
    # version had to escape \ then & just to cancel bash's own special-casing back out
    # to a literal ampersand. Perl's s/// replacement has no such special-casing --
    # $ename's runtime value is spliced in as literal text, already-escaped or not, so
    # escaping it here would introduce a stray backslash that was never in the name
    # (confirmed the hard way: a real name containing "&" round-tripped through the
    # bash-style double-escape came out "\&" instead of "&").
    $cmd =~ s/-r \Q$sid\E/-r "$ename"/;
  }

  # Display-only append -- sessions.txt (the parsed source) stays clean; a resumed
  # session gets Chrome control from the start. Skipped when chrome-by-default already
  # covers every launch (see $chrome_default above).
  $cmd .= " --chrome" unless $chrome_default;

  my $ctx = (defined $sid && exists $CTX{$sid}) ? $CTX{$sid} : '';

  # Bold field: ONE name -- the topic IS Claude Code's own session name, not a separate
  # harness identity. sessions.txt field 1 ($topic) normally carries it, because
  # sync_session_name keeps field 1 following the live name -- but only while the session
  # keeps taking turns. `/rename` a session and then walk away and field 1 is frozen on
  # the old name forever (confirmed real: 0bb7c2c3, renamed to harness-findability-wave,
  # still displayed debug-chrome-process-killer). Same staleness the resume handle had,
  # one field over, and the same render-time-fresh answer -- but ONLY for an explicit
  # rename, see %RENAMED above.
  # A session that drifted through several auto-titles is only findable by its LATEST
  # name here -- superseded ones are logged to session-names.txt (see rename-topic.sh)
  # instead of kept visible in this row, so that history isn't just lost.
  my $shortid = defined $sid ? (split(/-/, $sid))[0] : '';
  # Third case, below the two the comment above describes: field 1 can be the BARE SHORTID
  # -- a session whose name was never written back at all (5 rows here). The "don't let an
  # auto-title override the harness topic" rule assumes field 1 IS a topic; when it's a hex
  # string there is no topic to protect, and honouring the rule leaves the row displaying
  # `7b9cae8f` while its transcript has said `address-harness-gaps` 117 times. So for those
  # rows only, any name beats no name.
  my $display = display_name($topic, $sid);
  # The other half of the footer note: what the reader actually sees twice.
  $SHARED{$display} = 1 if ($NAMECOUNT{$display} // 0) > 1;

  my $ctx_disp = '—';
  if (length $ctx && $ctx ne '-') {
    my $idx = int($ctx / 25000);
    $idx = 24 if $idx > 24;
    my $color = $CTX_COLORS[$idx] // '#c91d1d';
    $ctx_disp = sprintf('<font color="%s">%s</font>', $color, humanize_ctx($ctx));
  }

  # Short id shown as its own field so it's easy to eyeball/grep against other
  # shortid-keyed tooling. Skipped when $display is ALREADY the bare shortid.
  my @f = (sprintf('**%s**', $display));
  push @f, $shortid if length $shortid && $shortid ne $display;
  push @f, sprintf('`%s`', $cmd);
  push @f, sprintf('**%s**', $ctx_disp);
  $out .= '- ' . join(' — ', @f) . "\n";
}

$out .= sprintf("\n_%d session(s) hidden — no transcript on this machine, or no context (never completed a turn) — not resumable._\n", $hidden)
  if $hidden > 0;
$out .= sprintf("\n_%d session(s) hidden — under %s context AND a small transcript (a compacted long-running session is not hidden). Still resumable: `grep <name> ~/.claude/sessions.txt`._\n", $small, humanize_ctx($MIN_CTX))
  if $small > 0;
$out .= sprintf("\n_%d older session(s) hidden — same name as a more recently active one shown above (context-continuation or fork). Still resumable: `grep <name> ~/.claude/sessions.txt`._\n", $superseded)
  if $superseded > 0;

# Two rows with the same bold name are baffling without this -- and the raw sid in their
# resume commands reads as a rendering miss rather than the deliberate fallback it is.
# Claude Code doesn't enforce unique session names: `/rename <name>` typed in two
# different sessions gives both that name, and nothing warns (confirmed real --
# cb8b1004 and 0bb7c2c3 both hold their own custom-title record for
# harness-findability-wave). scripts/session-name-taken.sh stops the harness's own
# rename-topic path suggesting a name that's already in use; this note covers the rest,
# since /rename is client-side and no hook can see it.
if (%SHARED) {
  my @names = sort keys %SHARED;
  $out .= sprintf("\n_%d name(s) shared by more than one session (%s) — those rows resume by id, since `claude -r <name>` can't pick one. Rename one of each pair to clear it._\n",
    scalar(@names), join(', ', map { "`$_`" } @names));
}

# ---- hash-guard against a concurrent renderer ----
# Re-read sessions.txt right before writing. If it changed since we started, a fresher
# render is either already in flight with newer data or the very next prompt triggers
# one anyway -- skip this write rather than risk clobbering a newer sessions.md with our
# now-stale snapshot. At ~1s render time this race is rare rather than the near-constant
# condition it was at 40s.
open my $sfh2, '<', $SESS or exit 0;
my @lines2 = <$sfh2>;
close $sfh2;
chomp @lines2;
exit 0 if join("\n", @lines2) ne $orig_snapshot;

# ---- write-through: same symlink-aware rename lib-sessions-lock.sh's
# sessions_write_through does in bash (sessions.md's real file lives in the harness
# repo; ~/.claude/sessions.md is a symlink to it -- rename() doesn't follow a symlink at
# the destination, so mv-ing straight onto it would replace the link itself with a
# plain file and silently detach future writes). $$-suffixed tmp path so concurrent
# renders never share one (the old shared "$OUT.tmp" could interleave two renders'
# output; a real defect, just a one-line fix once distinguished per process).
my $tmp = "$OUT.$$";
open my $ofh, '>', $tmp or exit 0;
print $ofh $out;
close $ofh;

my $dest = $OUT;
if (-l $dest) {
  my $real = readlink($dest);
  if (!defined $real || !length $real) { unlink $tmp; exit 1; }
  rename($tmp, $real) or do { unlink $tmp; exit 1; };
} else {
  rename($tmp, $dest) or do { unlink $tmp; exit 1; };
}
exit 0;
