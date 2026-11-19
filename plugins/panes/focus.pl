#!/usr/bin/perl
# prefix+h/j/k/l the tmux way, bound in config/commands.toml: when two or more
# panes are next to the focused one that way, go to the one focused last, not
# the first in layout order as herdr does. The pick is direction_target in
# Panes.pm.
#
# `focus.pl left|down|up|right` is the plugin action. `focus.pl focused` is
# the pane.focused hook (herdr-plugin.toml): it records every focus change,
# so focus moved by the mouse, prefix+q, prefix+; and the rest counts too.
use strict;
use warnings;
BEGIN { unshift @INC, __FILE__ =~ m{^(.*)/} ? $1 : '.' }
use Panes;

my ($arg) = grep { /\A(?:left|down|up|right|focused)\z/ } $ARGV[0] // '';
die "usage: focus.pl left|down|up|right|focused\n" unless $arg;
my $s = (api('session.snapshot', {}) // die "focus: no snapshot\n")->{snapshot};
my %live = map { $_->{pane_id} => 1 } map { @{ $_->{panes} } } @{ $s->{layouts} };

if ($arg eq 'focused') {
    my ($pane) = ($ENV{HERDR_PLUGIN_EVENT_JSON} // '') =~ /"pane_id"\s*:\s*"([^"]+)"/;
    stamp(\%live, $pane) if $pane && $live{$pane};
    exit 0;
}

my $from = $s->{focused_pane_id} // die "focus: no focused pane\n";
my $call = focus_call(layout($s, 1), $from, $arg, read_stamps());
my $r = api(@$call) // exit 1;

# The pane left, then the pane landed on, in one write: the first press
# after install already counts where it came from, and a fast next press
# does not wait for the hook.
my $to = $call->[0] eq 'pane.focus' ? $call->[1]{pane_id} : $r->{focus}{focused_pane_id} // $from;
stamp(\%live, $from, $to ne $from ? $to : ());
