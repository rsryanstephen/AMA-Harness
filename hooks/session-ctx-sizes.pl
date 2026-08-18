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
my $STATED = "$HOME/.claude/.session-chatfiles";

# Rows under this many tokens are hidden from sessions.md (display-only -- sessions.txt
# keeps every line). Small sessions did little worth returning to and crowd out the
# long-running ones the list exists to surface. Compared against the RAW token sum, not
# the rounded "Nk" display field.
my $MIN_CTX = 90_000;

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
for my $f (@files) {
  next unless -f $f;
  my ($sid) = $f =~ m{([^/\\]+)\.jsonl$};
  next unless $sid;
  my $size = -s $f;
  my $nz = scan_tail($f, $size, 300_000);
  $nz = scan_tail($f, $size, 3_000_000) unless defined $nz; # bounded fallback, not $size
  $CTX{$sid} = defined $nz ? $nz : '-';
}

# Reads the last $window bytes of $file, returns the summed token count from the LAST
# NONZERO "usage":{...} blob found (walking anchors backwards), or undef if every blob
# in the window is zero or there's no blob at all -- caller can't tell those two apart
# and doesn't need to, both mean "nothing to show" (see header comment).
sub scan_tail {
  my ($file, $size, $window) = @_;
  my $off = $size > $window ? $size - $window : 0;
  open my $fh, '<:raw', $file or return undef;
  seek $fh, $off, 0;
  local $/;
  my $buf = <$fh>;
  close $fh;
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

# lower-case, non-alnum runs squeezed to one "-", leading/trailing "-" trimmed -- same
# as the old `tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//'`.
sub slug {
  my ($s) = @_;
  $s = lc $s;
  $s =~ s/[^a-z0-9]+/-/g;
  $s =~ s/^-+//;
  $s =~ s/-+$//;
  return $s;
}

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

# Mirrors `$(cat "$STATED/$sid.$ext")` -- command substitution strips ALL trailing
# newlines, nothing else.
sub read_state {
  my ($sid, $ext) = @_;
  return '' unless defined $sid && length $sid;
  my $p = "$STATED/$sid.$ext";
  return '' unless -f $p;
  open my $fh, '<', $p or return '';
  local $/;
  my $c = <$fh>;
  close $fh;
  return '' unless defined $c;
  $c =~ s/[\r\n]+\z//;
  return $c;
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

my $out = "# Claude Code Sessions\n\n";
my $hidden = 0;
my $small = 0;

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
  # list exists to surface -- hidden below $MIN_CTX (raw token sum, not the rounded "Nk"
  # display field). Display-only, like the guard above: sessions.txt keeps the line, so
  # this is always resumable via `grep <name> sessions.txt`, unlike the unresumable bucket.
  if (defined $sid && length $sid && $CTX{$sid} < $MIN_CTX) {
    $small++;
    next;
  }

  my $ename = defined $sid ? read_state($sid, 'explicitname') : '';
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

  # Bold field: the harness topic wins by default -- it's the one name that ties a row
  # to a real artifact (the chat-log file on disk), and it's what sessions.txt itself
  # always shows, so grepping either file for it now finds the same rows. Claude Code's
  # own name (customTitle/agentName/aiTitle, latest wins) only takes over when the topic
  # itself carries no information -- either it's still the bare shortid placeholder, or
  # it's Claude Code's own derived "<dir>-<n>" placeholder that a fallback rename lifted
  # verbatim into the topic (lib-fallback-rename.sh step 3; e.g. "ama-claude-harness-f0").
  # See AGENTS.md's "Finding past sessions" section for the measured effect and the
  # 7-rule ladder this replaced (deleted along with it: a session reused across many
  # tasks can accumulate several different CC names over its life -- keeping the topic
  # is what makes a *specific* name findable again, not just the latest one Claude Code
  # happened to pick).
  my $shortid = defined $sid ? (split(/-/, $sid))[0] : '';
  my $ccname = length $ename ? $ename : (defined $sid ? read_state($sid, 'aititle') : '');
  my $ccs = slug($ccname);
  my $cph = defined $sid ? slug(read_state($sid, 'claudename')) : '';

  my $display = $topic;
  if (length $ccs && (($topic eq $shortid) || (length $cph && $topic eq $cph))) {
    $display = $ccs;
  }
  my $ccfield = (length $ccs && $ccs ne $display) ? $ccs : '';

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
  push @f, $ccfield if length $ccfield;
  push @f, $shortid if length $shortid && $shortid ne $display;
  push @f, sprintf('`%s`', $cmd);
  push @f, sprintf('**%s**', $ctx_disp);
  $out .= '- ' . join(' — ', @f) . "\n";
}

$out .= sprintf("\n_%d session(s) hidden — no transcript on this machine, or no context (never completed a turn) — not resumable._\n", $hidden)
  if $hidden > 0;
$out .= sprintf("\n_%d session(s) hidden — under %s context. Still resumable: `grep <name> ~/.claude/sessions.txt`._\n", $small, humanize_ctx($MIN_CTX))
  if $small > 0;

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
