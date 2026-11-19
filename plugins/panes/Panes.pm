package Panes;
# What display-panes.pl and focus.pl share: the socket API and the focused
# tab's layout. Also display-panes.pl's drawing of a pane as herdr draws it
# (text, scrollbar, border, in the user's theme's colours) and its opening of
# the popup without a blank frame - why that works is in its header - and
# focus.pl's pick of a neighbour and the focus records it picks by.
#
# Only light modules: until the popup opens, or focus moves, a key typed
# after the binding goes to the focused pane, so every ms of startup counts.
use strict;
use warnings;
use utf8;
use Exporter 'import';
use Fcntl qw(:flock);
use IO::Select;
use Socket qw(AF_UNIX SOCK_STREAM pack_sockaddr_un);
use Time::HiRes qw(time);

our @EXPORT = qw(
  theme_palette configured_theme config_path config_theme layout direction_target stamps_after focus_call
  scrollbar_thumb frame_start pane_lines pane_chrome frame_end api fence marker drop_marker marked wait_marker
  pane_text open_after_render session_dir read_stamps stamp make_state remove_state write_file read_lines json
);

my $JSON = eval { require JSON::XS; JSON::XS->new->utf8 }
  // do { require JSON::PP; JSON::PP->new->utf8 };

# The JSON coder api uses: UTF-8 bytes in and out.
sub json { $JSON }

use constant {
    PLUGIN_ID      => 'herdr-tmuxify.panes',
    SOURCE         => 'herdr-tmuxify:panes',
    FENCE_EVERY_MS => 2,
    MARKER_MAX_MS  => 200,    # first record normally in 15-40 ms
};

# The colours herdr paints pane borders and scrollbars in, per built-in theme
# (Palette in herdr v0.9.5's src/app/state.rs): pane borders are overlay0, the
# focused one accent; the scrollbar uses the rest. The popup repaints cells
# herdr drew in these colours, so they must be the user's theme's, or the
# borders flash a different colour while the numbers show. herdr exposes no
# theme colours through its API, hence the table; a new herdr theme needs a
# new row. The `terminal` theme is left out on purpose: its colours are ANSI
# names, which have no RGB value to paint. R;G;B, for an SGR 38;2 sequence.
my $DEFAULT_THEME = 'catppuccin';
my %THEMES = (
    'catppuccin'       => { accent => '137;180;250', overlay0 => '108;112;134', overlay1 => '127;132;156', surface_dim => '30;30;46'    },
    'catppuccin-latte' => { accent => '30;102;245',  overlay0 => '156;160;176', overlay1 => '140;143;161', surface_dim => '230;233;239' },
    'tokyo-night'      => { accent => '122;162;247', overlay0 => '86;95;137',   overlay1 => '105;113;150', surface_dim => '26;27;38'    },
    'tokyo-night-day'  => { accent => '46;125;233',  overlay0 => '137;144;179', overlay1 => '104;112;154', surface_dim => '210;211;218' },
    'dracula'          => { accent => '189;147;249', overlay0 => '98;114;164',  overlay1 => '130;140;180', surface_dim => '40;42;54'    },
    'nord'             => { accent => '136;192;208', overlay0 => '76;86;106',   overlay1 => '100;110;130', surface_dim => '46;52;64'    },
    'gruvbox'          => { accent => '215;153;33',  overlay0 => '146;131;116', overlay1 => '168;153;132', surface_dim => '40;40;40'    },
    'gruvbox-light'    => { accent => '7;102;120',   overlay0 => '146;131;116', overlay1 => '124;111;100', surface_dim => '242;229;188' },
    'one-dark'         => { accent => '97;175;239',  overlay0 => '92;99;112',   overlay1 => '115;122;135', surface_dim => '40;44;52'    },
    'one-light'        => { accent => '64;120;242',  overlay0 => '160;161;167', overlay1 => '104;107;119', surface_dim => '245;245;246' },
    'solarized'        => { accent => '38;139;210',  overlay0 => '88;110;117',  overlay1 => '101;123;131', surface_dim => '0;43;54'     },
    'solarized-light'  => { accent => '38;139;210',  overlay0 => '147;161;161', overlay1 => '88;110;117',  surface_dim => '238;232;213' },
    'kanagawa'         => { accent => '126;156;216', overlay0 => '114;113;105', overlay1 => '135;134;125', surface_dim => '31;31;40'    },
    'kanagawa-lotus'   => { accent => '77;105;155',  overlay0 => '160;156;172', overlay1 => '138;137;128', surface_dim => '213;206;163' },
    'rose-pine'        => { accent => '196;167;231', overlay0 => '110;106;134', overlay1 => '144;140;170', surface_dim => '38;35;58'    },
    'rose-pine-dawn'   => { accent => '144;122;169', overlay0 => '152;147;165', overlay1 => '121;117;147', surface_dim => '242;233;225' },
    'vesper'           => { accent => '255;199;153', overlay0 => '92;92;92',    overlay1 => '126;126;126', surface_dim => '16;16;16'    },
);

# The other spellings herdr accepts for a theme name (canonical_theme_name in
# src/config/theme.rs), after lower-casing and turning spaces and underscores
# into dashes.
my %THEME_ALIASES = (
    'catppuccin-mocha' => 'catppuccin',
    'latte'            => 'catppuccin-latte',
    'light'            => 'catppuccin-latte',
    'tokyonight'       => 'tokyo-night',
    'tokyo-day'        => 'tokyo-night-day',
    'tokyonight-day'   => 'tokyo-night-day',
    'gruvbox-dark'     => 'gruvbox',
    'onedark'          => 'one-dark',
    'onelight'         => 'one-light',
    'solarized-dark'   => 'solarized',
    'lotus'            => 'kanagawa-lotus',
    'rosepine'         => 'rose-pine',
    'rosepine-dawn'    => 'rose-pine-dawn',
    'dawn'             => 'rose-pine-dawn',
);

# The four colours for a theme name; the default theme's for a name that is
# unset, unknown or `terminal`.
sub theme_palette {
    my $name = lc($_[0] // '');
    $name =~ tr/ _/--/;
    $name = $THEME_ALIASES{$name} // $name;
    return $THEMES{$name} // $THEMES{$DEFAULT_THEME};
}

# The [theme] name in a config.toml's text, or undef. A line scan, not a TOML
# parser: it only has to find one key in one table. With auto_switch on, the
# active theme follows the host terminal's light/dark appearance, which this
# script cannot see, so it names none.
sub configured_theme {
    my ($toml) = @_;
    my ($table, $name, $auto) = ('');
    for my $line (split /\r?\n/, $toml // '') {
        if ($line =~ /^\s*\[\[?\s*([^\[\]]+?)\s*\]\]?\s*(?:#.*)?$/) { $table = $1; next }
        next unless $table eq 'theme';
        if    ($line =~ /^\s*name\s*=\s*(?:"([^"]*)"|'([^']*)')\s*(?:#.*)?$/) { $name = $1 // $2 }
        elsif ($line =~ /^\s*auto_switch\s*=\s*true\b/)                       { $auto = 1 }
    }
    return $auto ? undef : $name;
}

# Where herdr reads its config: HERDR_CONFIG_PATH if set, else config.toml under
# the XDG base directory, else under ~/.config.
sub config_path {
    return $ENV{HERDR_CONFIG_PATH} if length($ENV{HERDR_CONFIG_PATH} // '');
    my $base = length($ENV{XDG_CONFIG_HOME} // '') ? $ENV{XDG_CONFIG_HOME} : ($ENV{HOME} // '') . '/.config';
    return "$base/herdr/config.toml";
}

# The theme named in herdr's config file. Undef when it cannot be read.
sub config_theme {
    open my $fh, '<', config_path() or return undef;
    local $/;
    return configured_theme(scalar <$fh>);
}

# --- pure layer -------------------------------------------------------------

# The focused tab from a session snapshot: whether it is zoomed, the focused
# pane, its area, the popup's inner size, and panes 1-9 in layout order (with
# $all, every pane). A pane's col/row are the 1-based popup cell where its
# text starts - one cell inside its border, and the popup's origin is one
# cell inside the area, so the two cancel to rect - area + 1. w/h are its
# text area inside the border. The popup's inner size is the area less its
# border and one reserved column (src/popup_size.rs). max/off/vp are its
# scroll metrics, for the scrollbar.
sub layout {
    my ($s, $all) = @_;
    my ($l) = grep { $_->{tab_id} eq $s->{focused_tab_id} } @{ $s->{layouts} };
    my %scroll = map { $_->{pane_id} => ($_->{scroll} // {}) } @{ $s->{panes} // [] };
    my @panes = @{ $l->{panes} };
    splice @panes, 9 if @panes > 9 && !$all;
    my ($ax, $ay) = @{ $l->{area} }{qw(x y)};
    my $n = 0;
    return {
        zoomed  => $l->{zoomed} ? 1 : 0,
        focused => $s->{focused_pane_id},
        area    => $l->{area},
        rows    => $l->{area}{height} - 2,
        cols    => $l->{area}{width} - 3,
        panes   => [
            map {
                my ($r, $m) = ($_->{rect}, $scroll{ $_->{pane_id} } // {});
                +{
                    n       => ++$n,
                    id      => $_->{pane_id},
                    col     => $r->{x} - $ax + 1,
                    row     => $r->{y} - $ay + 1,
                    w       => $r->{width} - 2,
                    h       => $r->{height} - 2,
                    focused => $_->{focused} ? 1 : 0,
                    max     => $m->{max_offset_from_bottom} // 0,
                    off     => $m->{offset_from_bottom} // 0,
                    vp      => $m->{viewport_rows} // 0,
                    rect    => $r,
                };
            } @panes
        ],
    };
}

# prefix+h/j/k/l the tmux way: of the panes next to $from towards $dir, the
# one focused last ($stamps: pane id => time). herdr ranks them by edge
# distance, then overlap, then layout order (find_in_direction,
# src/layout.rs), so from a full-height pane two stacked neighbours always
# tie and the top one wins. The candidates are herdr's - beyond that edge,
# overlapping $from along it - cut to the nearest. undef lets herdr decide:
# a zoomed tab, fewer than two candidates, or none of them with a record.
sub direction_target {
    my ($lay, $from, $dir, $stamps) = @_;
    return undef if $lay->{zoomed};
    my ($f) = grep { $_->{id} eq $from } @{ $lay->{panes} } or return undef;
    my $fr = $f->{rect};
    my $across = $dir eq 'left' || $dir eq 'right';
    # The gap from $from's edge to a pane that way, or undef if it is not one.
    my $gap = sub {
        my ($r) = @_;
        my ($at, $len) = $across ? ('y', 'height') : ('x', 'width');
        return undef unless $r->{$at} < $fr->{$at} + $fr->{$len} && $r->{$at} + $r->{$len} > $fr->{$at};
        my $d = $dir eq 'left'  ? $fr->{x} - ($r->{x} + $r->{width})
              : $dir eq 'right' ? $r->{x} - ($fr->{x} + $fr->{width})
              : $dir eq 'up'    ? $fr->{y} - ($r->{y} + $r->{height})
              :                   $r->{y} - ($fr->{y} + $fr->{height});
        return $d >= 0 ? $d : undef;
    };
    my ($min, @near);
    for my $p (grep { $_->{id} ne $from } @{ $lay->{panes} }) {
        my $d = $gap->($p->{rect}) // next;
        if (!defined $min || $d < $min) { $min = $d; @near = ($p) }
        elsif ($d == $min)              { push @near, $p }
    }
    return undef if @near < 2;
    my $best;
    for my $p (grep { defined $stamps->{ $_->{id} } } @near) {
        $best = $p if !$best || $stamps->{ $p->{id} } > $stamps->{ $best->{id} };
    }
    return $best ? $best->{id} : undef;
}

# The focus records after @panes got focus, in that order, at $now. Panes
# missing from %$live have closed and are dropped.
sub stamps_after {
    my ($old, $live, $now, @panes) = @_;
    my %t = map { ($_ => $old->{$_}) } grep { $live->{$_} } keys %$old;
    $t{ $panes[$_] } = $now + $_ / 1000 for 0 .. $#panes;
    return \%t;
}

# The request that moves focus from $from towards $dir.
sub focus_call {
    my ($lay, $from, $dir, $stamps) = @_;
    my $to = direction_target($lay, $from, $dir, $stamps);
    return defined $to
      ? ['pane.focus', { pane_id => $to }]
      : ['pane.focus_direction', { pane_id => $from, direction => $dir }];
}

# The scrollbar thumb as (top, length) in track rows, or () when the pane
# has no scrollback - herdr's scrollbar_thumb (src/ui/scrollbar.rs).
sub scrollbar_thumb {
    my ($max, $off, $vp, $h) = @_;
    return if $max <= 0 || $h <= 0;
    my $len = int($vp * $h / ($max + $vp) + 0.5);
    $len = 1  if $len < 1;
    $len = $h if $len > $h;
    my $max_top = $h - $len;
    my $top = $max_top > 0 ? int(($max - $off) * $max_top / $max + 0.5) : 0;
    $top = $max_top if $top > $max_top;
    return ($top, $len);
}

# A popup frame is frame_start, then each pane's lines and chrome, then
# whatever the caller draws on top, then frame_end. Synchronized output
# (DEC 2026): herdr applies the frame as one update.
sub frame_start { "\e[?2026h\e[?25l\e[?7l\e[2J" }
sub frame_end   { "\e[?2026l" }

# A pane's text at its own cells. $text is pane.read's ANSI text.
sub pane_lines {
    my ($p, $lay, $text) = @_;
    my ($col, $row, $h) = @{$p}{qw(col row h)};
    my $out = '';
    my @lines = split /\r?\n/, $text // '';
    for my $i (0 .. $#lines) {
        last if $i >= $h || $row + $i > $lay->{rows};
        $out .= "\e[" . ($row + $i) . ";${col}H\e[0m$lines[$i]\e[0m";
    }
    return $out;
}

# A pane's scrollbar and border as herdr draws them. Cells outside the popup
# are dropped, which is how the outermost pane borders vanish under the
# popup's own border. $palette is theme_palette's; the default theme's when
# not given.
sub pane_chrome {
    my ($p, $lay, $palette) = @_;
    $palette //= theme_palette(undef);
    my ($rows, $cols) = @{$lay}{qw(rows cols)};
    my ($col, $row, $w, $h) = @{$p}{qw(col row w h)};
    my $in  = sub { $_[0] >= 1 && $_[0] <= $rows && $_[1] >= 1 && $_[1] <= $cols };
    my $fg  = sub { "\e[0;38;2;$palette->{$_[0]}m" };
    my $out = '';

    # herdr's pane scrollbar (render_pane_scrollbar_buffer,
    # src/ui/scrollbar.rs): down the last text column, only with
    # scrollback.
    if (my ($top, $len) = scrollbar_thumb(@{$p}{qw(max off vp)}, $h)) {
        my $c = $col + $w - 1;
        my ($track, $thumb, $symbol) =
          $p->{focused} ? ('overlay0', 'overlay1', '▐') : ('surface_dim', 'overlay0', '▕');
        for my $r (0 .. $h - 1) {
            next unless $in->($row + $r, $c);
            my $on = $r >= $top && $r < $top + $len;
            $out .= "\e[" . ($row + $r) . ";${c}H" . $fg->($on ? $thumb : $track)
              . ($on ? $symbol : '▕') . "\e[0m";
        }
    }

    $out .= $fg->($p->{focused} ? 'accent' : 'overlay0');
    for my $edge ([$row - 1, '┌', '┐'], [$row + $h, '└', '┘']) {
        my ($r, $left, $right) = @$edge;
        next unless $r >= 1 && $r <= $rows;
        my $line = '';
        my $start;
        for my $c ($col - 1 .. $col + $w) {
            next unless $in->($r, $c);
            $start //= $c;
            $line .= $c == $col - 1 ? $left : $c == $col + $w ? $right : '─';
        }
        $out .= "\e[$r;${start}H$line" if defined $start;
    }
    for my $c ($col - 1, $col + $w) {
        $out .= "\e[" . ($row + $_) . ";${c}H│" for grep { $in->($row + $_, $c) } 0 .. $h - 1;
    }
    return $out . "\e[0m";
}

# --- side effects -----------------------------------------------------------

my $SOCKET = $ENV{HERDR_SOCKET_PATH} // "$ENV{HOME}/.config/herdr/herdr.sock";

# api <method> <params>: one socket request; its result, or undef on error.
# In list context also the error, for callers that tell errors apart.
sub api {
    my ($method, $params) = @_;
    my $s;
    socket($s, AF_UNIX, SOCK_STREAM, 0) && connect($s, pack_sockaddr_un($SOCKET))
      or die "panes: connect $SOCKET: $!\n";
    syswrite $s, $JSON->encode({ id => 'panes', method => $method, params => $params }) . "\n";
    my $reply = <$s>;
    close $s;
    my $r = eval { $JSON->decode($reply // '') } // {};
    return wantarray ? ($r->{result}, $r->{error}) : $r->{result};
}

# Clearing a token that was never set: changes nothing, still renders.
sub fence {
    api('pane.report_metadata', { pane_id => $_[0], source => SOURCE, tokens => { panes_fence => undef } });
}

# marker <pane>: a fresh observer whose first record will mark a render.
# Observers never exit by themselves, and perl waits for a piped child when
# it closes the handle, so every one started is killed at exit too. A marker
# started early, before this module loaded, is adopted with marker(undef,
# $early).
my @observers;
sub marker {
    my ($pane, $early) = @_;
    my ($fh, $pid);
    if ($early) {
        ($fh, $pid) = @{$early}{qw(fh pid)};
    } else {
        my $herdr = $ENV{HERDR_BIN_PATH} // 'herdr';
        $pid = open($fh, '-|', $herdr, 'terminal', 'session', 'observe', $pane) or return;
    }
    push @observers, $pid;
    return { fh => $fh, pid => $pid, sel => IO::Select->new($fh) };
}
END { kill 'TERM', @observers if @observers }

sub drop_marker { kill 'TERM', $_[0]{pid} if $_[0] }

# Whether the marker has already recorded a render.
sub marked { $_[0] && $_[0]{sel}->can_read(0) }

# Wait for the marker's first record, fencing every FENCE_EVERY_MS so that a
# render comes even when nothing is drawing. 1 once it arrives, 0 at the cap.
sub wait_marker {
    my ($m, $pane) = @_;
    return 0 unless $m;
    my $deadline = time + MARKER_MAX_MS / 1000;
    while (time < $deadline) {
        return 1 if $m->{sel}->can_read(FENCE_EVERY_MS / 1000);
        fence($pane);
    }
    return 0;
}

sub pane_text {
    my $r = api('pane.read', { pane_id => $_[0], source => 'visible', format => 'ansi' });
    return $r ? $r->{read}{text} : '';
}

# Open this plugin's popup pane $entry right after a render (see the header
# of display-panes.pl), with %$env in its environment. $m is a marker
# started early, so it attached while the frame was built; if a render
# already used up its first record, start a fresh one.
sub open_after_render {
    my ($m, $pane, $entry, $env) = @_;
    if (!$m || marked($m)) {
        drop_marker($m);
        $m = marker($pane);
    }
    # No record (the observer failed): open after a fence and hope.
    fence($pane) unless wait_marker($m, $pane);
    drop_marker($m);
    return api('plugin.pane.open', { plugin_id => PLUGIN_ID, entrypoint => $entry, env => $env });
}

# This plugin's state for one herdr session: the focus records
# direction_target reads. Keyed by the session's socket: the plugin's state
# dir is one for all sessions (plugin_state_dir, src/plugin_paths.rs), and
# pane ids repeat across them.
sub session_dir {
    (my $key = $ENV{HERDR_SOCKET_PATH} // 'default') =~ s/[^\w.-]/_/g;
    return ($ENV{HERDR_PLUGIN_STATE_DIR} // $ENV{TMPDIR} // '/tmp') . "/$key";
}

# The focus records, pane id => time. Read without the lock: a write lands
# whole, by rename.
sub read_stamps {
    my %t = map { /\A([^\t]+)\t([\d.]+)\z/ ? ($1, $2) : () } read_lines(session_dir() . '/stamps');
    return \%t;
}

# Record that @panes got focus, in that order. $live is the set of panes the
# snapshot still has. Both writers - the pane.focused hook and the focus
# action - read and write the whole file, so the lock keeps one from undoing
# the other's write.
sub stamp {
    my ($live, @panes) = @_;
    my $dir = session_dir();
    mkdir $dir, 0700;
    open my $lock, '>', "$dir/stamps.lock" or return;
    flock $lock, LOCK_EX or return;
    my $t = stamps_after(read_stamps(), $live, time, @panes);
    write_file("$dir/stamps.$$", join '', map { "$_\t" . sprintf('%.3f', $t->{$_}) . "\n" } sort keys %$t);
    rename "$dir/stamps.$$", "$dir/stamps";
}

# A state dir for one run, and its removal.
sub make_state {
    my $state = ($ENV{HERDR_PLUGIN_STATE_DIR} // $ENV{TMPDIR} // '/tmp') . "/frame.$$";
    mkdir $state, 0700 or die "panes: $state: $!\n";
    return $state;
}

sub remove_state {
    my ($state) = @_;
    unlink glob "$state/*";
    rmdir $state;
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die "panes: $path: $!\n";
    print {$fh} $content;
    close $fh;
}

sub read_lines {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or return;
    chomp(my @lines = <$fh>);
    return @lines;
}

1;
