#!/usr/bin/env perl
# One name per session, enforced after the fact on IDLE transcripts.
#
#   perl session-name-dedupe.pl [--dry-run]        auto: fix every shared name
#   perl session-name-dedupe.pl --rename <sid> <name>   explicit rename of one idle session
#
# WHY. Claude Code copies a session's name into a new sid on /compact-continue, on a fork
# (rewind/branch), and on a bare /clear -- and enforces no uniqueness. Two holders of one
# name -> `claude -r "<name>"` opens the picker, sessions.md falls back to raw ids and
# lists the name in its "shared" footer (19 names, 2026-10-22). /rename is client-side, but
# a rename is just a record appended to the transcript, so an IDLE session (no client
# holding it open) can be renamed by appending the same three records /rename + the
# auto-titler write: custom-title, agent-name, ai-title. All three, because
# session-ctx-sizes.pl and session-name-taken.pl count all three.
#
# Two kinds of sharing, told apart from the transcripts themselves:
#   LINEAGE  -- same conversation in several sids: one starts with "being continued from a
#               previous conversation" (/compact), or both share the first user message's
#               uuid (fork copies history verbatim). Every holder but the latest-active one
#               becomes "<name> - superseded by <latest sid8>"; sessions.md hides those.
#   DISTINCT -- different conversations (a bare /clear copies the name into an unrelated
#               new session). The later-started one becomes "<name> (<own sid8>)", the
#               same suffix convention the chat-file collision path already uses.
# A holder written in the last $IDLE_SECS is never touched (a live client re-appends its
# in-memory title and would clobber the rename) -- it is retried on a later run.
use strict;
use warnings;
use JSON::PP;
use File::Copy qw(copy);

my $HOME = $ENV{HOME};
my $IDLE_SECS = 30 * 60;
my $HARNESS = do { my $d = $0; $d =~ s{[/\\][^/\\]+$}{}; "$d/.." };
my $DRY = 0;

sub slugify {
  my ($s) = @_;
  $s = lc($s // '');
  $s =~ s/[^a-z0-9]+/-/g;
  $s =~ s/^-+|-+$//g;
  return $s;
}

# This script's own lineage marker. Grouping ignores it, so a retired part stays in its
# lineage and can be re-evaluated (or handed the name back) on every run.
sub strip_marker {
  my ($s) = @_;
  $s =~ s/ - superseded by [0-9a-f]{8}$//;
  return $s;
}

sub find_transcript {
  my ($sid) = @_;
  for my $f (glob("$HOME/.claude/projects/*/$sid*.jsonl")) { return $f if -f $f; }
  return undef;
}

# Appends the three title records to an idle transcript, backs it up first, then lets the
# harness's own sync path move the chat file + sessions.txt field 1 to the new name.
sub rename_session {
  my ($sid, $name) = @_;
  my $f = find_transcript($sid) or do { warn "no transcript for $sid\n"; return 0 };
  ($sid) = $f =~ m{([0-9a-f-]{36})\.jsonl$};
  my $age = time - (stat $f)[9];
  if ($age < $IDLE_SECS) { print "skip (live, written ${age}s ago): $sid\n"; return 0; }
  print(($DRY ? "would rename" : "rename"), ": ", substr($sid, 0, 8), " -> $name\n");
  return 1 if $DRY;

  my $bdir = "$HOME/.claude/scratch/session-renames";
  mkdir "$HOME/.claude/scratch"; mkdir $bdir;
  copy($f, "$bdir/$sid.jsonl.bak") or do { warn "backup failed for $sid: $!\n"; return 0 };

  open my $rh, '<:raw', $f or return 0;
  seek $rh, -1, 2; read $rh, my $last, 1; close $rh;
  my $json = JSON::PP->new->canonical(0);
  my @recs = (
    { type => 'custom-title', customTitle => $name, sessionId => $sid },
    { type => 'agent-name',   agentName   => $name, sessionId => $sid },
    { type => 'ai-title',     aiTitle     => $name, sessionId => $sid },
  );
  open my $ah, '>>:raw', $f or return 0;
  print $ah "\n" if defined $last && $last ne "\n";
  print $ah $json->encode($_), "\n" for @recs;
  close $ah;

  my $chat = '';
  if (open my $ch, '<', "$HOME/.claude/.session-chatfiles/$sid") { $chat = <$ch> // ''; close $ch; }
  $chat =~ s/[\r\n]+$//;
  if (length $chat && -f $chat) {
    my $lib = "$HARNESS/hooks/lib-fallback-rename.sh";
    my $dir = $chat; $dir =~ s{[/\\][^/\\]+$}{};
    system('bash', '-c', 'source "$1" && sync_session_name "$2" "$3" "$4" "$5"', '_',
      $lib, $sid, $chat, $dir, $f);
  }
  return 1;
}

if (@ARGV && $ARGV[0] eq '--rename') {
  my (undef, $sid, $name) = @ARGV;
  die "usage: session-name-dedupe.pl --rename <sid> <name>\n" unless $sid && defined $name && length $name;
  exit(rename_session($sid, $name) ? 0 : 1);
}
$DRY = 1 if @ARGV && $ARGV[0] eq '--dry-run';

# ---- census: latest title fields, first user message, continuation flag, last activity ----
my (%holders, %S, %INTXT);
if (open my $s, '<', "$HOME/.claude/sessions.txt") {
  while (<$s>) { $INTXT{$1} = 1 if /claude -r ([0-9a-f-]{36})/; }
  close $s;
}
my @files = `find "$HOME/.claude/projects" -name '*.jsonl' -not -path '*/subagents/*' 2>/dev/null`;
chomp @files;
for my $f (@files) {
  my ($sid) = $f =~ m{([0-9a-f-]{36})\.jsonl$} or next;
  my $size = -s $f or next;
  open my $fh, '<:raw', $f or next;
  my ($first_uuid, $first_ts, $cont) = ('', '', 0);
  my %last;
  my $read = 0;
  while (my $line = <$fh>) {
    $read += length $line;
    while ($line =~ /"(customTitle|agentName|aiTitle)":"((?:[^"\\]|\\.)*)"/g) { $last{$1} = $2; }
    if (!length $first_uuid && $line =~ /"type":"user"/ && $line !~ /"isMeta":true/) {
      ($first_uuid) = $line =~ /"uuid":"([^"]+)"/;
      ($first_ts) = $line =~ /"timestamp":"([^"]+)"/;
      $cont = 1 if $line =~ /being continued from a previous conversation/;
      $first_uuid //= '';
    }
    last if length $first_uuid && $read > 64_000;
    last if $read > 8_000_000;
  }
  my $off = $size > 300_000 ? $size - 300_000 : 0;
  $off = $read if $off < $read;
  seek $fh, $off, 0;
  my $tail = do { local $/; <$fh> } // '';
  close $fh;
  while ($tail =~ /"(customTitle|agentName|aiTitle)":"((?:[^"\\]|\\.)*)"/g) { $last{$1} = $2; }
  # Rank by the last prompt the user TYPED, not any timestamp: a task notification landing in
  # an old continuation would otherwise hand it the name (same rule as session-ctx-sizes.pl's
  # last_typed_ts, keep in step).
  my $typed;
  for my $l (split /\n/, $tail) {
    next unless index($l, '"type":"user"') >= 0 && $l =~ /"content":"(?!<(?:task-notification|local-command|command-name|system-reminder))/;
    next if $l =~ /"isMeta":true/;
    $typed = $1 if $l =~ /"timestamp":"([^"]+)"/;
  }
  my @ts = $tail =~ /"timestamp":"([^"]+)"/g;
  my $last_ts = $typed // (sort @ts)[-1] // $first_ts // '';
  $S{$sid} = { first_uuid => $first_uuid, first_ts => $first_ts // '', cont => $cont,
               last_ts => $last_ts, names => {} };
  for my $k (qw(customTitle agentName aiTitle)) {
    next unless defined $last{$k} && length $last{$k};
    my $n = $last{$k};
    $n =~ s/\\(["\\\/])/$1/g;
    $S{$sid}{names}{$k} = $n;
    push @{$holders{slugify(strip_marker($n))}{$k}}, $sid;
  }
}

# ---- resolve each shared name that some holder carries as a handle (custom/agent) ----
my $acted = 0;
my %done;
for my $slug (sort keys %holders) {
  my %by = %{$holders{$slug}};
  my %sids = map { $_ => 1 } map { @$_ } values %by;
  my @sids = grep { !$done{$_} } keys %sids;
  next unless @sids > 1;
  # aiTitle-only sharing matters once 2+ holders are listed rows (Toprow: 3 continuations,
  # aiTitle only, all in sessions.txt) -- the renderer's footer counts those too.
  next unless $by{customTitle} || $by{agentName} || (grep { $INTXT{$_} } @sids) > 1;
  my $k = $by{customTitle} ? 'customTitle' : $by{agentName} ? 'agentName' : 'aiTitle';
  my $name = strip_marker($S{$by{$k}[0]}{names}{$k});

  # Group into lineages: shared first-message uuid, or a continuation joins the group of
  # the holder it most plausibly continued (all continuations of one name -> one lineage).
  my @lineage = grep { $S{$_}{cont} } @sids;
  my %uuid_groups;
  push @{$uuid_groups{$S{$_}{first_uuid} || $_}}, $_ for @sids;
  my @groups = values %uuid_groups;
  if (@lineage) {
    # Continuations carry no shared uuid; fold every group containing a continuation, plus
    # the oldest-started non-continuation group (the root it was compacted from), into one.
    my @roots = sort { $S{$a->[0]}{first_ts} cmp $S{$b->[0]}{first_ts} }
                grep { !grep { $S{$_}{cont} } @$_ } @groups;
    my @conts = grep { grep { $S{$_}{cont} } @$_ } @groups;
    my @merged = map { @$_ } @conts;
    push @merged, @{shift @roots} if @roots;
    @groups = (\@merged, @roots);
  }

  # LINEAGE: within each group, keep the latest-active, supersede the rest.
  my @keepers;
  for my $g (@groups) {
    # A sessions.txt-listed holder beats an unlisted one (61dc5d69 vs 4402d507): the keeper
    # is the row sessions.md shows, so it must be one sessions.md can show.
    my @by_last = sort { ($INTXT{$b} // 0) <=> ($INTXT{$a} // 0) || $S{$b}{last_ts} cmp $S{$a}{last_ts} } @$g;
    my $keep = shift @by_last;
    push @keepers, $keep;
    # Name the superseded part after the keeper's handle, not whichever field matched (an
    # aiTitle like "Production errors in Graylog" isn't what the row is called). CC's own
    # " (N)" continuation suffix dropped.
    my $kn = $S{$keep}{names};
    my $base = strip_marker($kn->{customTitle} // $kn->{agentName} // $name);
    $base =~ s/\s\(\d{1,2}\)$//;
    # Activity moved back to a part an earlier run retired (3072582c: marked superseded by
    # its own /compact continuation, then resumed and used past it) -> give it the name back.
    # Live keeper -> rename_session skips it; next run retries once it is idle.
    my $cur = $kn->{customTitle} // $kn->{agentName} // '';
    $acted += rename_session($keep, $base) if $cur ne strip_marker($cur);
    $done{$keep} = 1;
    for my $old (@by_last) {
      my $want = "$base - superseded by " . substr($keep, 0, 8);
      my $on = $S{$old}{names};
      $acted += rename_session($old, $want) if ($on->{customTitle} // $on->{agentName} // '') ne $want;
      $done{$old} = 1;
    }
  }
  # DISTINCT: several groups still share the name -> later-started keepers take a suffix.
  my @by_start = sort { $S{$a}{first_ts} cmp $S{$b}{first_ts} } @keepers;
  shift @by_start;
  for my $later (@by_start) {
    $acted += rename_session($later, "$name (" . substr($later, 0, 8) . ")");
    $done{$later} = 1;
  }
}
print "session-name-dedupe: $acted rename(s)", ($DRY ? " (dry run)" : ""), "\n";
exit 0;
