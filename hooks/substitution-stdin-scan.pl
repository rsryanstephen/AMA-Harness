#!/usr/bin/perl
# Reads a shell command on STDIN. Prints the name of the first stdin-reading filter whose file
# operands ALL come from an unquoted command substitution, else nothing. Used by
# substitution-stdin-hang-gate.sh -- see that file's header for why the rule exists.
#
# Its own file, not an inline `perl -e` in the gate: unanalyzable-script-gate.sh denies inline
# control flow in a Bash call, so an inline version could never be tested from a tool call.
# Precedent: session-ctx-sizes.pl, session-name-taken.pl.
use strict;
use warnings;

# Filters that read STDIN when given no file operand. NOT `tr`/`cut -d`: tr takes no file operand
# at all, so a substitution there is a different (non-hanging) mistake.
my %FILTER = map { $_ => 1 } qw(grep egrep fgrep rg awk sed jq wc cat head tail sort uniq nl
                                comm paste md5sum sha1sum sha256sum);
# These consume one non-option operand as a pattern/script/program BEFORE any file operand.
my %PATTERN_ARG = map { $_ => 1 } qw(grep egrep fgrep rg awk sed jq);

my $s = do { local $/; <STDIN> };
exit 0 unless defined $s && length $s;

# --- split into pipeline segments, remembering which ones get stdin from a pipe ---------------
# A `;` or `|` INSIDE $( ) or quotes must not split, hence the hand-rolled walk.
my (@seg, @piped);
my $cur = "";
my $cur_piped = 0;
my ($sq, $dq, $depth, $bt) = (0, 0, 0, 0);
my @ch = split //, $s;
for (my $i = 0; $i <= $#ch; $i++) {
  my $c = $ch[$i];
  if ($c eq "\\" && !$sq) { $cur .= $c . (defined $ch[$i+1] ? $ch[$i+1] : ""); $i++; next; }
  if ($c eq "'" && !$dq && !$bt) { $sq = !$sq; $cur .= $c; next; }
  if ($c eq '"' && !$sq && !$bt) { $dq = !$dq; $cur .= $c; next; }
  # Backtick substitution: same role as $( ), so a `;`/`|` inside one must not split a segment.
  if ($c eq '`' && !$sq && !$dq)  { $bt = !$bt; $cur .= $c; next; }
  if (!$sq && !$dq && !$bt) {
    if ($c eq '$' && defined $ch[$i+1] && $ch[$i+1] eq "(") { $depth++; $cur .= '$('; $i++; next; }
    if ($c eq "(" && $depth) { $depth++; $cur .= $c; next; }
    if ($c eq ")" && $depth) { $depth--; $cur .= $c; next; }
    if (!$depth) {
      my $two = $c . (defined $ch[$i+1] ? $ch[$i+1] : "");
      if ($two eq "&&" || $two eq "||") {
        push @seg, $cur; push @piped, $cur_piped; $cur = ""; $cur_piped = 0; $i++; next;
      }
      if ($c eq "|") { push @seg, $cur; push @piped, $cur_piped; $cur = ""; $cur_piped = 1; next; }
      if ($c eq ";" || $c eq "\n" || $c eq "&") {
        push @seg, $cur; push @piped, $cur_piped; $cur = ""; $cur_piped = 0; next;
      }
    }
  }
  $cur .= $c;
}
push @seg, $cur; push @piped, $cur_piped;

# --- test each segment that does NOT already have stdin ---------------------------------------
for my $n (0 .. $#seg) {
  next if $piped[$n];                          # stdin comes from the pipe: never blocks
  my $seg = $seg[$n];
  next unless $seg =~ /\S/;
  next if $seg =~ /(?<![0-9<>])<(?!<)/;        # explicit stdin redirect (</dev/null) -- the fix

  my @tok = tokenize($seg);
  shift @tok while @tok && $tok[0] =~ /^[A-Za-z_][A-Za-z0-9_]*=/;   # leading env assignments
  next unless @tok;
  my $cmd = shift @tok;
  $cmd =~ s{.*[/\\]}{};                                            # strip any path prefix
  next unless $FILTER{$cmd};

  # Operands vs options. Everything after a bare `--` is an operand.
  my @ops;
  my $endopts = 0;
  for my $a (@tok) {
    if (!$endopts && $a eq "--")  { $endopts = 1; next; }
    if (!$endopts && $a =~ /^-./) { next; }
    push @ops, $a;
  }
  shift @ops if $PATTERN_ARG{$cmd} && @ops;    # pattern/script/program, not a file
  next unless @ops;

  # The hang needs EVERY operand to be an unquoted substitution: one literal file and the filter
  # never falls through to stdin.
  my $all_subst = 1;
  for my $a (@ops) { $all_subst = 0 unless $a =~ /^\$\(/ || $a =~ /^`/; }
  next unless $all_subst;

  print $cmd;
  exit 0;
}
exit 0;

# Split one segment into top-level words, keeping quotes and substitutions intact.
sub tokenize {
  my ($seg) = @_;
  my @tok;
  my $t = "";
  my ($tsq, $tdq, $td, $tbt) = (0, 0, 0, 0);
  my @tc = split //, $seg;
  for (my $i = 0; $i <= $#tc; $i++) {
    my $c = $tc[$i];
    if ($c eq "\\" && !$tsq) { $t .= $c . (defined $tc[$i+1] ? $tc[$i+1] : ""); $i++; next; }
    if ($c eq "'" && !$tdq && !$tbt) { $tsq = !$tsq; $t .= $c; next; }
    if ($c eq '"' && !$tsq && !$tbt) { $tdq = !$tdq; $t .= $c; next; }
    # A backtick substitution is ONE operand however much whitespace it contains.
    if ($c eq '`' && !$tsq && !$tdq)  { $tbt = !$tbt; $t .= $c; next; }
    if (!$tsq && !$tdq && !$tbt) {
      if ($c eq '$' && defined $tc[$i+1] && $tc[$i+1] eq "(") { $td++; $t .= '$('; $i++; next; }
      if ($c eq "(" && $td) { $td++; $t .= $c; next; }
      if ($c eq ")" && $td) { $td--; $t .= $c; next; }
      if (!$td && $c =~ /\s/) { push @tok, $t if length $t; $t = ""; next; }
    }
    $t .= $c;
  }
  push @tok, $t if length $t;
  return @tok;
}
