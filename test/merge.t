#!/usr/bin/perl
# Checks lib/merge.pl: the tagged-line merge of herdr-tmuxify's config
# fragments into a herdr config.toml, and its exact inverse. Pure text in,
# text out; `herdr config check` is replaced by a fake validator, so no herdr
# is needed. Run: perl test/merge.t
use strict;
use warnings;
use FindBin;
use Test::More;

require "$FindBin::Bin/../lib/merge.pl";

# A small fragment with every unit kind: scalars in two tables, and two
# command blocks, one of which depends on a scalar.
my $frag = parse_fragment(<<'TOML');
[keys]
detach = "prefix+d"
workspace_picker = "prefix+s"
close_pane = ""

[ui.sidebar.spaces]
rows = [["state_icon"], ["branch"]]

# requires: keys.detach
[[keys.command]]
key = "prefix+q"
type = "plugin_action"
command = "x.show"

# requires: keys.close_pane
[[keys.command]]
key = "prefix+x"
type = "popup"
command = "y"
TOML

is scalar(@{ $frag->{scalars} }), 4, 'fragment: four scalars';
is scalar(@{ $frag->{blocks} }), 2, 'fragment: two command blocks';
is_deeply $frag->{blocks}[0]{requires}, 'keys.detach', 'fragment: a block names the scalar it needs';
is $frag->{blocks}[0]{key}, 'prefix+q', 'fragment: a block knows its chord';

sub status_of { my ($rep, $what) = @_; my ($r) = grep { $_->{what} eq $what } @$rep; return $r ? $r->{status} : 'none' }
sub detail_of { my ($rep, $what) = @_; my ($r) = grep { $_->{what} eq $what } @$rep; return $r ? $r->{detail} : '' }
sub install { my ($text, %o) = @_; my ($out, $rep) = merge_config($text, $frag, %o); return ($out, $rep) }

# --- a fresh config ---------------------------------------------------------

my $T = '# herdr-tmuxify';
my ($fresh, $rep) = install('');
is $fresh, <<"OUT", 'empty config: tables, lines and one marked block';
[keys] $T
detach = "prefix+d" $T
workspace_picker = "prefix+s" $T
close_pane = "" $T

[ui.sidebar.spaces] $T
rows = [["state_icon"], ["branch"]] $T

# >>> herdr-tmuxify >>>
[[keys.command]]
key = "prefix+q"
type = "plugin_action"
command = "x.show"
[[keys.command]]
key = "prefix+x"
type = "popup"
command = "y"
# <<< herdr-tmuxify <<<
OUT
is status_of($rep, 'keys.detach'), 'applied', 'report: scalar applied';
is status_of($rep, 'command prefix+q'), 'applied', 'report: block applied';
is unmerge($fresh), '', 'unmerge returns an empty config to empty';

# --- an existing config -------------------------------------------------------

my $mine = <<'TOML';
onboarding = false

[keys]
prefix = "ctrl+a"

[ui]
pane_borders = "always"
TOML
my ($merged) = install($mine);
like $merged, qr/^\[keys\]\nprefix = "ctrl\+a"\n/m, "the user's lines are untouched";
like $merged, qr/^detach = "prefix\+d" \Q$T\E$/m, 'our line lands in their [keys]';
unlike $merged, qr/^\[keys\] \Q$T\E/m, 'no second [keys] table';
is unmerge($merged), $mine, 'install then unmerge: the original bytes';
my ($again) = install(unmerge($merged));
is $again, $merged, 'install is idempotent';

# A key of the same name in another table is not the user's setting.
my ($other) = install("[ui.sidebar.spaces]\nunrelated = 1\n[keys]\nx = 1\n");
like $other, qr/^\[keys\]\nx = 1\ndetach = "prefix\+d" \Q$T\E$/m, 'inserted into the right table';
is status_of((install("[ui]\nrows = 3\n"))[1], 'ui.sidebar.spaces.rows'), 'applied', 'rows in [ui] is another key';

# --- conflicts ---------------------------------------------------------------

my ($c, $crep) = install(qq{[keys]\ndetach = "prefix+q"\n});
is status_of($crep, 'keys.detach'), 'skipped', "a different value of the user's own is left alone";
like $c, qr/^detach = "prefix\+q"$/m, '... and stays as written';
like detail_of($crep, 'keys.detach'), qr/detach = "prefix\+d"/, '... and the report says what to add by hand';
is status_of($crep, 'command prefix+q'), 'skipped', 'a block whose scalar was not applied is skipped';
like detail_of($crep, 'command prefix+q'), qr/keys\.detach/, '... naming the scalar';

my ($s, $srep) = install(qq{[keys]\ndetach = 'prefix+d'\n});
is status_of($srep, 'keys.detach'), 'same', 'the same value in other quotes counts as set';
unlike $s, qr/detach.*\Q$T\E/, '... and adds no line';
is status_of($srep, 'command prefix+q'), 'applied', '... so the block that needs it applies';

my ($cm) = install(qq{[keys]\n# detach = "prefix+q"\n});
like $cm, qr/^detach = "prefix\+d" \Q$T\E$/m, 'a commented-out key is not set';

# --force: the user's line is replaced, reversibly.
my $theirs = qq{[keys]\n  detach = "prefix+q"  # my choice\n};
my ($f, $frep) = install($theirs, force => 1);
is status_of($frep, 'keys.detach'), 'replaced', '--force replaces a single-line value';
like $f, qr/^# herdr-tmuxify-replaced:   detach = "prefix\+q"  # my choice$/m, '... keeping the original line';
is unmerge($f), $theirs, '... and unmerge restores it byte for byte';
my ($ml, $mlrep) = install(qq{[keys]\ndetach = [\n  "a",\n]\n}, force => 1);
is status_of($mlrep, 'keys.detach'), 'skipped', '--force does not touch a multi-line value';

# --- the prefix option ---------------------------------------------------------

my ($p) = install('', prefix => 'ctrl+space');
like $p, qr/^prefix = "ctrl\+space" \Q$T\E$/m, '--prefix adds a prefix line';
my ($p2) = install(unmerge($p), prefix => 'ctrl+a');
like $p2, qr/^prefix = "ctrl\+a" \Q$T\E$/m, 'a later run with another prefix replaces ours';
unlike $p2, qr/ctrl\+space/, '... leaving no trace of the old one';
my ($pc, $pcrep) = install(qq{[keys]\nprefix = "ctrl+b"\n}, prefix => 'ctrl+space');
is status_of($pcrep, 'keys.prefix'), 'skipped', "--prefix does not override the user's own prefix";

# --- the validator (herdr config check) ------------------------------------------

# herdr reports a chord given to two explicit bindings and disables one.
my $dup = sub {
    my ($t) = @_;
    return () unless $t =~ /^settings = "prefix\+s"/m && $t =~ /^workspace_picker = "prefix\+s"/m;
    return ('prefix+s: kept keys.settings, disabled keys.workspace_picker');
};
my ($v, $vrep) = install(qq{[keys]\nsettings = "prefix+s"\n}, check => $dup);
is status_of($vrep, 'keys.workspace_picker'), 'skipped', 'a unit that makes the check worse is dropped';
like detail_of($vrep, 'keys.workspace_picker'), qr/kept keys\.settings/, '... with the check\'s own words';
unlike $v, qr/workspace_picker/, '... and is not written';
is status_of($vrep, 'keys.detach'), 'applied', 'the other units still apply';

# Diagnostics the file already had are not ours to answer for.
my $old = sub { return ('keys.bogus: unknown config key') };
my ($o, $orep) = install(qq{[keys]\nbogus = 1\n}, check => $old);
is status_of($orep, 'keys.detach'), 'applied', 'pre-existing diagnostics do not block a unit';

# A shape the line editor cannot extend produces a parse error; that is a skip.
# TOML forbids `[keys]` after a root-level `keys.x = ...`, which is how a user
# might have written that table.
my $parse = sub {
    my ($t) = @_;
    return $t =~ /^keys\./m && $t =~ /^\[keys\]/m ? ('config parse error: duplicate key `keys`') : ();
};
my ($pe, $perep) = install(qq{keys.prefix = "x"\n}, check => $parse);
is status_of($perep, 'keys.detach'), 'skipped', 'a dotted-key config the editor cannot extend: the unit is skipped';
like detail_of($perep, 'keys.detach'), qr/parse error/, "... with herdr's words, and nothing is written";
unlike $pe, qr/detach|\[keys\]/, '... no half-applied [keys] lines';
is status_of($perep, 'ui.sidebar.spaces.rows'), 'applied', '... while a unit in another table still applies';
is status_of($perep, 'command prefix+x'), 'skipped', '... and so are the blocks that needed it';

# --- uninstall details ----------------------------------------------------------------

# Lines the user added under a header we created keep that header.
my ($grown) = install('');
$grown =~ s/^(\[keys\] \Q$T\E\n)/$1mine = 1\n/m;
my $after = unmerge($grown);
like $after, qr/^\[keys\]\nmine = 1\n/, 'a created table the user extended keeps its header';
unlike $after, qr/herdr-tmuxify/, '... without our tag';
is $after, "[keys]\nmine = 1\n", '... and nothing else of ours is left';

# A config with CRLF-free text but a blank line before our block comes back exactly.
my $spaced = qq{a = 1\n\n\n};
my ($sp) = install($spaced);
is unmerge($sp), $spaced, 'blank lines before our additions survive the round trip';

# --- blocks -----------------------------------------------------------------------------

my ($b) = install(qq{[[keys.command]]\nkey = "prefix+z"\ntype = "popup"\ncommand = "z"\n});
like $b, qr/^\[\[keys\.command\]\]\nkey = "prefix\+z"/m, "the user's own command block is untouched";
# herdr keeps the first of two command blocks on one chord and disables the second.
my $dupblk = sub {
    my ($t) = @_;
    return () unless (() = $t =~ /key = "prefix\+x"/g) > 1;
    return ('prefix+x: kept keys.command[0].key, disabled keys.command[1].key');
};
my ($bx, $bxrep) = install(qq{[[keys.command]]\nkey = "prefix+x"\ntype = "popup"\ncommand = "mine"\n}, check => $dupblk);
is status_of($bxrep, 'command prefix+x'), 'skipped', "a block on a chord the user's block already uses is dropped";
like $bx, qr/command = "mine"/, "... and theirs stays";
is status_of($bxrep, 'command prefix+q'), 'applied', '... while the other block applies';

# --- the real fragments --------------------------------------------------------------------

my $real = load_fragments("$FindBin::Bin/../config");
my %have = map { ("$_->{table}.$_->{key}" => $_->{value}) } @{ $real->{scalars} };
is $have{'keys.split_horizontal'}, q{'prefix+"'}, 'config: split_horizontal keeps its literal-quote spelling';
is $have{'keys.split_vertical'}, '"prefix+percent"', 'config: split_vertical';
is $have{'keys.copy_mode'}, '"prefix+["', 'config: copy_mode keeps its literal bracket';
is $have{'keys.detach'}, '"prefix+d"', 'config: detach moves off prefix+q';
is $have{'keys.close_pane'}, '""', 'config: close_pane is unbound for the popup';
ok exists $have{'ui.sidebar.spaces.rows'}, 'config: the sidebar rows line';
ok !exists $have{'keys.prefix'}, 'config: no prefix unless asked';
ok !grep({ /focus_agent|theme|pane_borders|tab_bar_right/ } keys %have), 'config: nothing personal';
is join(',', map { $_->{key} } @{ $real->{blocks} }), 'prefix+x,prefix+ampersand,prefix+q', 'config: three command blocks';
my %need = map { ($_->{key} => $_->{requires}) } @{ $real->{blocks} };
is_deeply \%need, { 'prefix+x' => 'keys.close_pane', 'prefix+ampersand' => 'keys.close_tab', 'prefix+q' => 'keys.detach' },
    'config: each popup names the scalar it needs';
my ($whole, $wrep) = merge_config('', $real);
is unmerge($whole), '', 'config: the real fragments round-trip an empty file';
ok !grep({ $_->{status} eq 'skipped' } @$wrep), 'config: nothing is skipped on an empty file';

done_testing;
