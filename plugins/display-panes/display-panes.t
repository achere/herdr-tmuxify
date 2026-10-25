#!/usr/bin/perl
# Checks display-panes.pl's pure layer: snapshot in, layout, keys, scrollbar
# and frame out. No herdr server involved. Run: perl display-panes.t
use strict;
use warnings;
use utf8;
use FindBin;
use Test::More;

require "$FindBin::Bin/display-panes.pl";

# Shaped like a real session.snapshot (herdr 0.9.3): the focused tab w1:t2
# holds a left pane and a right column split in two. A second tab's layout
# is present to prove only the focused tab is used.
my $three = {
    focused_tab_id  => 'w1:t2',
    focused_pane_id => 'w1:p3',
    panes => [
        { pane_id => 'w1:p3', scroll => { max_offset_from_bottom => 22, offset_from_bottom => 0, viewport_rows => 24 } },
        { pane_id => 'w1:p2' },
    ],
    layouts => [
        { tab_id => 'w1:t1', zoomed => 0, area => { x => 0, y => 0, width => 176, height => 51 },
          panes => [{ pane_id => 'w1:p9', focused => 1, rect => { x => 0, y => 0, width => 176, height => 51 } }] },
        { tab_id => 'w1:t2', zoomed => 0, area => { x => 0, y => 0, width => 176, height => 51 },
          panes => [
              { pane_id => 'w1:p2', focused => 0, rect => { x => 0,  y => 0,  width => 88, height => 51 } },
              { pane_id => 'w1:p3', focused => 1, rect => { x => 88, y => 0,  width => 88, height => 26 } },
              { pane_id => 'w1:p4', focused => 0, rect => { x => 88, y => 26, width => 88, height => 25 } },
          ] },
    ],
};

my $lay = layout($three);
is_deeply [map { "$_->{n} $_->{id} $_->{col} $_->{row} $_->{w} $_->{h} $_->{focused}" } @{ $lay->{panes} }],
  ['1 w1:p2 1 1 86 49 0', '2 w1:p3 89 1 86 24 1', '3 w1:p4 89 27 86 23 0'],
  'panes numbered in layout order; text starts at rect - area + 1';
is "@{$lay->{panes}[1]}{qw(max off vp)}", '22 0 24', 'scroll metrics come from .panes';
is "@{$lay->{panes}[0]}{qw(max off vp)}", '0 0 0',   'a pane without them has none';
is "$lay->{rows} $lay->{cols}", '49 173', 'popup inner size: border each side plus one reserved column';
is $lay->{zoomed}, 0, 'focused tab not zoomed';
is $lay->{focused}, 'w1:p3', 'focused pane';

# An area that does not start at 0,0 shifts every pane by the same amount.
my $offset = layout({
    focused_tab_id => 'w1:t1', focused_pane_id => 'w1:p1',
    layouts => [{ tab_id => 'w1:t1', zoomed => 1, area => { x => 10, y => 2, width => 100, height => 40 },
                  panes => [{ pane_id => 'w1:p1', focused => 1, rect => { x => 10, y => 2, width => 100, height => 40 } }] }],
});
is "@{$offset->{panes}[0]}{qw(n col row w h)}", '1 1 1 98 38', 'area offset is subtracted';
is $offset->{zoomed}, 1, 'zoomed tab reported';

my $ten = layout({
    focused_tab_id => 't',
    layouts => [{ tab_id => 't', zoomed => 0, area => { x => 0, y => 0, width => 200, height => 10 },
                  panes => [map { +{ pane_id => "p$_", focused => 0, rect => { x => ($_ - 1) * 20, y => 0, width => 20, height => 10 } } } 1 .. 10] }],
});
is scalar @{ $ten->{panes} }, 9, 'only nine panes get numbers';

is pane_for_key('2', $lay->{panes}), 'w1:p3', 'digit picks its pane';
is pane_for_key('4', $lay->{panes}), undef, 'digit past the last pane';
is pane_for_key('q', $lay->{panes}), undef, 'non-digit picks nothing';
is pane_for_key('0', $lay->{panes}), undef, 'zero picks nothing';
is pane_for_key('',  $lay->{panes}), undef, 'empty key (timeout) picks nothing';

# herdr's scrollbar_thumb: 42 visible of 64 rows in a 42-row track.
is_deeply [scrollbar_thumb(22, 0, 42, 42)],   [14, 28], 'thumb at the bottom';
is_deeply [scrollbar_thumb(22, 22, 42, 42)],  [0, 28],  'thumb at the top';
is_deeply [scrollbar_thumb(5000, 0, 10, 42)], [41, 1],  'thumb at least one row';
is_deeply [scrollbar_thumb(0, 0, 42, 42)],    [],       'no scrollback, no thumb';

# Frame: two panes side by side in a 20x8 area -> a 6x17 popup. The outer
# borders fall outside the popup; the two inner ones stay.
my $pair = layout({
    focused_tab_id => 't', focused_pane_id => 'a',
    panes => [{ pane_id => 'a', scroll => { max_offset_from_bottom => 5, offset_from_bottom => 0, viewport_rows => 6 } }],
    layouts => [{ tab_id => 't', zoomed => 0, area => { x => 0, y => 0, width => 20, height => 8 },
                  panes => [
                      { pane_id => 'a', focused => 1, rect => { x => 0,  y => 0, width => 10, height => 8 } },
                      { pane_id => 'b', focused => 0, rect => { x => 10, y => 0, width => 10, height => 8 } },
                  ] }],
});
my $frame = frame($pair, { a => "ab\r\ncd", b => "x\e[31my\e[0m" }, theme_palette('one-dark'));
like $frame, qr/\A\e\[\?2026h/, 'frame is one synchronized update';
like $frame, qr/\e\[\?2026l\z/, '... closed at the end';
like $frame, qr/\e\[1;1H\e\[0mab\e\[0m/, 'pane text at its own cell';
like $frame, qr/\e\[2;1H\e\[0mcd\e\[0m/, '... line by line; the last line has no newline';
like $frame, qr/\e\[1;11H\e\[0mx\e\[31my\e\[0m\e\[0m/, "pane colours are kept";
like $frame, qr/\e\[1;9H│/, "left pane's right border inside the popup";
like $frame, qr/\e\[1;10H│/, "right pane's left border inside the popup";
unlike $frame, qr/[┌┐└┘─]/, 'borders on the area edge fall under the popup border';
like $frame, qr/\e\[0;38;2;97;175;239m\e\[\d+;9H│/, 'focused pane border is accent';
# 6 visible of 11 rows, at the bottom: a 3-row thumb under a 3-row track.
like $frame, qr/\e\[1;8H\e\[0;38;2;92;99;112m▕/,   'focused pane scrollbar track';
like $frame, qr/\e\[4;8H\e\[0;38;2;115;122;135m▐/, 'focused pane scrollbar thumb';
like $frame, qr/\e\[41m \e\[0m/, 'focused pane digit is red';
like $frame, qr/\e\[44m \e\[0m/, 'other pane digit is blue';

# The border and scrollbar colours follow the user's theme: the popup repaints
# cells herdr drew in the theme's colours, so a mismatch shows as a flash.
my $texts = { a => 'ab', b => 'x' };
like frame($pair, $texts, theme_palette('nord')), qr/\e\[0;38;2;136;192;208m\e\[\d+;9H│/,
    'a given palette colours the focused border';
like frame($pair, $texts), qr/\e\[0;38;2;137;180;250m\e\[\d+;9H│/,
    'no palette: the default theme (catppuccin)';

# theme_palette: a theme name in, the four colours out.
is theme_palette('one-dark')->{accent},      '97;175;239',  'one-dark accent';
is theme_palette('one-dark')->{surface_dim}, '40;44;52',    'one-dark surface_dim';
is theme_palette('Rose Pine')->{accent},     '196;167;231', 'names are lower-cased and spaces become dashes';
is theme_palette('onedark')->{accent},       '97;175;239',  'an alias resolves to its theme';
is theme_palette('light')->{accent},         '30;102;245',  'light is the catppuccin-latte alias';
is_deeply theme_palette(undef),      theme_palette('catppuccin'), 'no name: default theme';
is_deeply theme_palette('nonsense'), theme_palette('catppuccin'), 'unknown name: default theme';
# terminal's colours are ANSI names, not RGB values, so there is nothing to paint.
is_deeply theme_palette('terminal'), theme_palette('catppuccin'), 'terminal: default theme';
for my $name (qw(catppuccin catppuccin-latte tokyo-night tokyo-night-day dracula nord gruvbox
                 gruvbox-light one-dark one-light solarized solarized-light kanagawa
                 kanagawa-lotus rose-pine rose-pine-dawn vesper)) {
    my $p = theme_palette($name);
    is_deeply [sort keys %$p], [qw(accent overlay0 overlay1 surface_dim)], "$name has all four colours";
}

# config_path: where herdr reads its config. HERDR_CONFIG_PATH wins, then the
# XDG base directory, then ~/.config. Reading the wrong file would hand the
# popup the wrong colours without any error.
{
    local %ENV = (HOME => '/h');
    is config_path(), '/h/.config/herdr/config.toml', 'config path: under HOME by default';
    $ENV{XDG_CONFIG_HOME} = '/x';
    is config_path(), '/x/herdr/config.toml', '... XDG_CONFIG_HOME moves it';
    $ENV{XDG_CONFIG_HOME} = '';
    is config_path(), '/h/.config/herdr/config.toml', '... an empty XDG_CONFIG_HOME is unset';
    $ENV{XDG_CONFIG_HOME} = '/x';
    $ENV{HERDR_CONFIG_PATH} = '/p/c.toml';
    is config_path(), '/p/c.toml', '... HERDR_CONFIG_PATH wins over both';
}

# configured_theme: the config file's text in, the [theme] name out.
is configured_theme(qq{[theme]\nname = "nord"\n}), 'nord', 'reads [theme] name';
is configured_theme(qq{[theme]\nname = 'dracula'\n}), 'dracula', 'single-quoted string';
is configured_theme(qq{[ui]\nname = "x"\n[theme]\nname = "nord"\n}), 'nord', 'ignores name in other tables';
is configured_theme(qq{[theme]\nname = "nord"  # dark\n}), 'nord', 'trailing comment';
is configured_theme(qq{[theme]\n# name = "nord"\n}), undef, 'a commented name is not a name';
is configured_theme(qq{[keys]\nprefix = "ctrl+a"\n}), undef, 'no [theme] table';
is configured_theme(''), undef, 'empty config';
# With auto_switch the active theme depends on the host's appearance, which
# this script cannot see; a wrong guess is worse than the default.
is configured_theme(qq{[theme]\nname = "nord"\nauto_switch = true\n}), undef, 'auto_switch: no single theme';
is configured_theme(qq{[theme]\nname = "nord"\nauto_switch = false\n}), 'nord', 'auto_switch off';

done_testing;
