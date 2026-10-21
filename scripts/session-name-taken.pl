#!/usr/bin/env perl
# Is a candidate session name already in use by ANOTHER session?
#
#   perl session-name-taken.pl "<candidate>" [<this session's sid>]
#
# Exit 0  -- TAKEN. Prints one "<shortid>  <name>" line per colliding session.
# Exit 1  -- free (prints nothing).
# Exit 2  -- usage error.
#
# WHY. Claude Code does not enforce unique session names: `/rename <name>` typed in two
# different sessions gives both that name and warns about nothing -- confirmed real,
# cb8b1004 and 0bb7c2c3 each hold their own custom-title record for
# harness-findability-wave. The cost isn't cosmetic: `claude -r "<name>"` with two matches
# drops the user in the resume PICKER instead of resuming, so sessions.md has to fall back
# to a raw session id for every row involved.
#
# This is the preventable half -- skills/rename-topic runs it before recommending a name.
# It CANNOT catch a `/rename` typed straight into the client: that is client-side, no hook
# or tool ever sees it. sessions.md's "name(s) shared" footer covers that half after the
# fact.
#
# Perl, not bash, for the same reason session-ctx-sizes.pl is: this walks every transcript
# on the machine, and process spawn here measures ~0.55s -- a shell version forking `tr`
# and `sed` per candidate comparison took minutes. Same 300KB tail read and same three
# fields as that renderer's own name census, so the two agree by construction.
#
# aiTitle counts even though the harness never prints it as a resume handle: Claude Code's
# picker matched a session carrying only an aiTitle (30a58b66), so it makes a name
# ambiguous all the same. Comparison is slug-insensitive -- "README hook" and "readme-hook"
# are the same name here, one being just the chat-file spelling of the other.
use strict;
use warnings;

my $HOME = $ENV{HOME};
my ($candidate, $self) = @ARGV;
unless (defined $candidate && length $candidate) {
  print STDERR "usage: session-name-taken.pl \"<candidate name>\" [<own sid>]\n";
  exit 2;
}
$self = '' unless defined $self;

sub slugify {
  my ($s) = @_;
  $s = lc($s // '');
  $s =~ s/[^a-z0-9]+/-/g;
  $s =~ s/^-+|-+$//g;
  return $s;
}

my $want = slugify($candidate);
unless (length $want) {
  print STDERR "session-name-taken.pl: candidate slugs to nothing\n";
  exit 2;
}

my %hit;   # sid -> the name it collides with

# 1. sessions.txt field 1 -- the harness topic, which is also the chat file's name.
if (open my $sfh, '<', "$HOME/.claude/sessions.txt") {
  while (my $line = <$sfh>) {
    chomp $line;
    next unless length $line;
    my ($topic) = split(/ /, $line, 2);
    my ($sid) = $line =~ /claude -r (\S+)/;
    next unless defined $sid && defined $topic;
    next if $sid eq $self;
    $hit{$sid} = $topic if slugify($topic) eq $want;
  }
  close $sfh;
}

# 2. Every transcript's own latest customTitle / agentName / aiTitle.
my @files = `find "$HOME/.claude/projects" -name '*.jsonl' -not -path '*/subagents/*' 2>/dev/null`;
chomp @files;
for my $f (@files) {
  next unless -f $f;
  my ($sid) = $f =~ m{([^/\\]+)\.jsonl$};
  next unless $sid;
  next if $sid eq $self || exists $hit{$sid};

  my $size = -s $f;
  my $off = $size > 300_000 ? $size - 300_000 : 0;
  open my $fh, '<:raw', $f or next;
  seek $fh, $off, 0;
  local $/;
  my $buf = <$fh>;
  close $fh;
  next unless defined $buf;

  my %last;
  while ($buf =~ /"(customTitle|agentName|aiTitle)":"([^"]*)"/g) { $last{$1} = $2; }
  for my $field (qw(customTitle agentName aiTitle)) {
    next unless defined $last{$field};
    next unless slugify($last{$field}) eq $want;
    $hit{$sid} = $last{$field};
    last;
  }
}

exit 1 unless %hit;
printf("%s  %s\n", (split(/-/, $_))[0], $hit{$_}) for sort keys %hit;
exit 0;
