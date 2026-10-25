#!/usr/bin/env perl
# Adds herdr-tmuxify's config fragments to a herdr config.toml, or removes them.
#
#   merge.pl install   CONFIG FRAGMENT_DIR [--prefix KEY] [--force] [--check CMD]
#   merge.pl uninstall CONFIG
#
# CONFIG is rewritten in place (through a symlink, never over it). The report
# goes to stdout, one tab-separated `status  what  detail` line per unit.
#
# Everything this adds is tagged, so removing it is exact:
#   - a scalar line ends in ` # herdr-tmuxify`;
#   - a table header it had to create ends in the same tag;
#   - a line of yours it replaced (--force) is kept as
#     `# herdr-tmuxify-replaced: <your original line>`;
#   - command bindings sit in one block between `# >>> herdr-tmuxify >>>` and
#     `# <<< herdr-tmuxify <<<`.
# Install is "remove everything of ours, then merge", so re-running it, or
# running it with other options, never stacks.
#
# This is a line editor, not a TOML parser. It does not need to be one: each
# unit is added on its own and kept only if the validator (herdr's own
# `config check`) shows nothing it did not already show. A shape the editor
# cannot extend, such as `keys.prefix = ...` written as a dotted key, produces
# a parse error, so the unit is skipped with herdr's words, never half-applied.
use strict;
use warnings;

our $TAG      = '# herdr-tmuxify';
our $REPLACED = '# herdr-tmuxify-replaced: ';
our $BEGIN    = '# >>> herdr-tmuxify >>>';
our $END      = '# <<< herdr-tmuxify <<<';

# --- text as lines ------------------------------------------------------------

# A file's lines, without newlines. A missing final newline is not kept: the
# result always ends in one. (An empty file stays empty.)
sub split_text {
    my @l = split /\n/, $_[0] // '', -1;
    pop @l if @l && $l[-1] eq '';
    return @l;
}

sub join_text { return @_ ? join("\n", @_) . "\n" : '' }

# --- reading the user's TOML ---------------------------------------------------

# The name in a `[table]` header (not `[[array]]`), or undef.
sub header_name {
    return $_[0] =~ /^\s*\[\s*([^\[\]]+?)\s*\]\s*(?:#.*)?$/ ? $1 : undef;
}

sub is_header { return $_[0] =~ /^\s*\[/ }

# [first line, one past the last] of a table, or nothing.
sub find_table {
    my ($lines, $name) = @_;
    (my $want = $name) =~ s/\s+//g;
    for my $i (0 .. $#$lines) {
        my $n = header_name($lines->[$i]);
        next unless defined $n;
        (my $got = $n) =~ s/\s+//g;
        next unless $got eq $want;
        my $end = $i + 1;
        $end++ while $end <= $#$lines && !is_header($lines->[$end]);
        return ($i, $end);
    }
    return;
}

# The value text after `key =`, without its trailing comment, and whether it
# runs over more than one line. Quote-aware, enough for the values herdr uses.
sub scan_value {
    my ($s) = @_;
    $s =~ s/^\s+//;
    if ($s =~ /^("""|''')/) {
        my $q = $1;
        my $n = () = $s =~ /\Q$q\E/g;
        $s =~ s/\s+$//;
        return ($s, $n < 2);
    }
    my ($out, $q, $depth, $esc) = ('', '', 0, 0);
    for my $c (split //, $s) {
        if ($q) {
            $out .= $c;
            if    ($esc)                    { $esc = 0 }
            elsif ($c eq '\\' && $q eq '"') { $esc = 1 }
            elsif ($c eq $q)                { $q = '' }
            next;
        }
        if ($c eq '"' || $c eq "'") { $q = $c; $out .= $c; next }
        last if $c eq '#';
        $depth++ if $c eq '[' || $c eq '{';
        $depth-- if $c eq ']' || $c eq '}';
        $out .= $c;
    }
    $out =~ s/\s+$//;
    return ($out, $depth != 0 || $q ne '');
}

# Two spellings of one value compare equal: 'a' and "a", or arrays that differ
# only in white space.
sub norm_value {
    my ($v) = @_;
    $v =~ s/^\s+|\s+$//g;
    return "s:$1" if $v =~ /^"((?:[^"\\]|\\.)*)"$/ || $v =~ /^'([^']*)'$/;
    $v =~ s/\s+//g;
    return "r:$v";
}

sub quote_string { my ($s) = @_; $s =~ s/(["\\])/\\$1/g; return qq{"$s"} }

# --- the fragments ----------------------------------------------------------------

# Scalars (`key = value` under a `[table]`) and command blocks (`[[keys.command]]`
# followed by its key lines) from one fragment file's text. A block ends at the
# first blank or comment line. A `# requires: table.key` comment above a block
# names the scalar that must be in effect for the block to be added.
sub parse_fragment {
    my ($toml) = @_;
    my (@scalars, @blocks, $table, $requires, $cur);
    for my $line (split /\n/, $toml) {
        if ($cur) {
            if ($line =~ /^\s*$/ || $line =~ /^\s*#/ || $line =~ /^\s*\[/) {
                push @blocks, $cur;
                undef $cur;
            } else {
                push @{ $cur->{lines} }, $line;
                $cur->{key} = $1 if $line =~ /^key\s*=\s*"([^"]*)"/;
                next;
            }
        }
        if ($line =~ /^\s*#\s*requires:\s*(\S+)/) { $requires = $1; next }
        if ($line =~ /^\s*\[\[\s*keys\.command\s*\]\]\s*$/) {
            $cur = { lines => [$line], requires => $requires };
            undef $requires;
            next;
        }
        if ($line =~ /^\s*\[\s*([^\[\]]+?)\s*\]\s*$/) { $table = $1; next }
        if (defined $table && $line =~ /^([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$/) {
            push @scalars, { table => $table, key => $1, value => $2 };
        }
    }
    push @blocks, $cur if $cur;
    return { scalars => \@scalars, blocks => \@blocks };
}

sub read_text {
    open my $fh, '<', $_[0] or return '';
    local $/;
    return scalar <$fh>;
}

# All of the fragment files in a directory, in a fixed order.
sub load_fragments {
    my ($dir) = @_;
    my %all = (scalars => [], blocks => []);
    for my $f (qw(keys.toml ui.toml commands.toml)) {
        my $p = parse_fragment(read_text("$dir/$f"));
        push @{ $all{scalars} }, @{ $p->{scalars} };
        push @{ $all{blocks} },  @{ $p->{blocks} };
    }
    return \%all;
}

# --- adding a scalar ------------------------------------------------------------------

# Puts `key = value` in [table] of @$lines. Returns 'applied' (new line),
# 'replaced' (--force, your line kept as a comment), 'same' (already set to
# this), or ('skipped', your value).
sub apply_scalar {
    my ($lines, $table, $key, $value, $force) = @_;
    my $new = "$key = $value $TAG";
    my ($start, $end) = find_table($lines, $table);
    if (!defined $start) {
        push @$lines, '' if @$lines;
        push @$lines, "[$table] $TAG", $new;
        return 'applied';
    }
    for my $i ($start + 1 .. $end - 1) {
        next unless $lines->[$i] =~ /^\s*\Q$key\E\s*=\s*(.*)$/;
        my ($have, $multi) = scan_value($1);
        return 'same' if !$multi && norm_value($have) eq norm_value($value);
        return ('skipped', $have) if $multi || !$force;
        splice @$lines, $i, 1, "$REPLACED$lines->[$i]", $new;
        return 'replaced';
    }
    # After the table's last setting, so your lines stay on top. Trailing blank
    # and comment lines are skipped: a comment there describes the next table.
    my $at = $start;
    for my $i ($start + 1 .. $end - 1) { $at = $i if $lines->[$i] !~ /^\s*(?:#|$)/ }
    splice @$lines, $at + 1, 0, $new;
    return 'applied';
}

# --- adding a command block ---------------------------------------------------------

sub region_bounds {
    my ($lines) = @_;
    my ($b, $e);
    for my $i (0 .. $#$lines) {
        if (!defined $b) { $b = $i if $lines->[$i] eq $BEGIN; next }
        if ($lines->[$i] eq $END) { $e = $i; last }
    }
    return defined $e ? ($b, $e) : ();
}

sub add_block {
    my ($lines, $block) = @_;
    my ($b, $e) = region_bounds($lines);
    if (defined $b) {
        splice @$lines, $e, 0, @$block;
    } else {
        push @$lines, '' if @$lines;
        push @$lines, $BEGIN, @$block, $END;
    }
}

# --- install and uninstall ------------------------------------------------------------

sub rep { return { status => $_[0], what => $_[1], detail => $_[2] // '' } }

# $text with everything of ours added. Options: prefix => KEY, force => 1,
# check => sub { my ($text) = @_; return @diagnostics }. Returns the new text
# and a report.
sub merge_config {
    my ($text, $frag, %o) = @_;
    my $check = $o{check} // sub { () };
    my @lines = split_text(unmerge($text));
    my @report;
    my %base = map { $_ => 1 } $check->(join_text(@lines));

    my @scalars = @{ $frag->{scalars} };
    unshift @scalars, { table => 'keys', key => 'prefix', value => quote_string($o{prefix}) }
        if defined $o{prefix};

    my %want;       # "table.key" => the value we want, for requires
    my %effective;  # "table.key" => 1 once that value is in effect
    for my $u (@scalars) {
        my $what = "$u->{table}.$u->{key}";
        $want{$what} = $u->{value};
        my $by_hand = "add under [$u->{table}]: $u->{key} = $u->{value}";
        my @cand = @lines;
        my ($res, $have) = apply_scalar(\@cand, $u->{table}, $u->{key}, $u->{value}, $o{force});
        if ($res eq 'same') {
            push @report, rep('same', $what, 'already set to the same value');
            $effective{$what} = 1;
            next;
        }
        if ($res eq 'skipped') {
            push @report, rep('skipped', $what, "you set it to $have; to use ours, $by_hand");
            next;
        }
        my @all  = $check->(join_text(@cand));
        my @diag = grep { !$base{$_} } @all;
        if (@diag) {
            push @report, rep('skipped', $what, "herdr's config check says: $diag[0]; to use ours, $by_hand");
            next;
        }
        @lines = @cand;
        %base = map { $_ => 1 } @all;
        $effective{$what} = 1;
        push @report, rep($res, $what);
    }

    for my $blk (@{ $frag->{blocks} }) {
        my $what = "command $blk->{key}";
        if (defined(my $need = $blk->{requires})) {
            unless ($effective{$need}) {
                my $v = $want{$need} // '(not in the fragments)';
                push @report, rep('skipped', $what, "needs $need = $v in effect, and it is not");
                next;
            }
        }
        my @cand = @lines;
        add_block(\@cand, $blk->{lines});
        my @all  = $check->(join_text(@cand));
        my @diag = grep { !$base{$_} } @all;
        if (@diag) {
            push @report, rep('skipped', $what, "herdr's config check says: $diag[0]");
            next;
        }
        @lines = @cand;
        %base = map { $_ => 1 } @all;
        push @report, rep('applied', $what);
    }
    return (join_text(@lines), \@report);
}

# $text with everything of ours removed; the exact inverse of merge_config for a
# file that ends in a newline and has not been edited since.
sub unmerge {
    my ($text) = @_;
    my @l = split_text($text);

    if ((my ($b, $e) = region_bounds(\@l))) {
        splice @l, $b, $e - $b + 1;
        splice @l, $b - 1, 1 if $b > 0 && $l[$b - 1] eq '';
    }

    my @out;
    for my $line (@l) {
        if ($line =~ /^\Q$REPLACED\E(.*)$/) { push @out, $1; next }
        next if $line =~ /^\s*[^\s\[#].*\s\Q$TAG\E$/;
        push @out, $line;
    }

    # A table header we created goes with its lines, unless you added lines of
    # your own under it, in which case it stays, minus the tag.
    for (my $i = $#out; $i >= 0; $i--) {
        next unless $out[$i] =~ /^\s*\[.*\s\Q$TAG\E$/;
        my $end = $i + 1;
        $end++ while $end <= $#out && !is_header($out[$end]);
        if (grep { $_ !~ /^\s*$/ } @out[$i + 1 .. $end - 1]) {
            $out[$i] =~ s/\s\Q$TAG\E$//;
        } else {
            splice @out, $i, 1;
            if ($i > 0 && $out[$i - 1] eq '') {
                splice @out, $i - 1, 1;
                $i--;
            }
        }
    }
    return join_text(@out);
}

# --- command line ---------------------------------------------------------------------

# A validator for merge_config that runs `CMD FILE` and takes its output lines
# as the diagnostics.
sub command_check {
    my ($cmd) = @_;
    return sub {
        my ($text) = @_;
        require File::Temp;
        my ($fh, $path) = File::Temp::tempfile('merge-XXXXXX', TMPDIR => 1, UNLINK => 1);
        print {$fh} $text;
        close $fh;
        open(my $ph, '-|', $cmd, $path) or return ();
        my @d = grep { length } map { s/\s+$//r } <$ph>;
        close $ph;
        return @d;
    };
}

sub main {
    my ($mode, $config, @rest) = @_;
    die "usage: merge.pl install CONFIG FRAGMENT_DIR [--prefix KEY] [--force] [--check CMD]\n"
      . "       merge.pl uninstall CONFIG\n" unless $mode && $config;
    my $text = read_text($config);
    my $out;
    if ($mode eq 'uninstall') {
        $out = unmerge($text);
    } elsif ($mode eq 'install') {
        my $dir = shift @rest or die "merge.pl: install needs FRAGMENT_DIR\n";
        my %o;
        while (@rest) {
            my $a = shift @rest;
            if    ($a eq '--prefix') { $o{prefix} = shift @rest // die "merge.pl: --prefix needs a value\n" }
            elsif ($a eq '--check')  { $o{check}  = command_check(shift @rest // die "merge.pl: --check needs a command\n") }
            elsif ($a eq '--force')  { $o{force}  = 1 }
            else                     { die "merge.pl: unknown option $a\n" }
        }
        my $report;
        ($out, $report) = merge_config($text, load_fragments($dir), %o);
        print join("\t", $_->{status}, $_->{what}, $_->{detail}), "\n" for @$report;
    } else {
        die "merge.pl: unknown mode $mode\n";
    }
    if ($out ne $text) {
        open my $fh, '>', $config or die "merge.pl: $config: $!\n";
        print {$fh} $out;
        close $fh or die "merge.pl: $config: $!\n";
    }
}

main(@ARGV) unless caller;
1;
