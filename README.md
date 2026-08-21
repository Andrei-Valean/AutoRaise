# AutoRaise

Hover a window and it comes to the front and takes the focus, after a delay of your choosing.
Optionally it also warps the mouse into the window you activate with cmd-tab or cmd-grave.
See also [the stackoverflow question](https://stackoverflow.com/questions/98310/focus-follows-mouse-plus-auto-raise-on-mac-os-x)
this started from.

## Quick start

1. Download the [latest release](https://github.com/sbmpost/AutoRaise/releases/latest) and open the
   disk image.
2. Drag AutoRaise into Applications, then open it.
3. Allow accessibility access when macOS asks. AutoRaise waits for the permission and starts the
   moment you grant it, no restart needed.
4. Use the menu bar icon to pause it, open Settings, or have it open at login.

## Settings

Open the menu bar icon and choose Settings, or press command-comma. Every change applies
immediately, and is written to the settings file as you make it.

The window has six pages:

- **General**: the master switch, open at login, the menu bar icon, and a global shortcut to pause
  and resume from anywhere.
- **Raise & Focus**: whether a hovered window is raised, focused first and raised later, or only
  focused, plus the delays for each, how much pointer movement to ignore, and the outline that marks
  a window holding the keyboard without having been raised.
- **Pointer**: mouse warping on window switch, with any switcher. Drag the pointer around a small window to say where
  it should land.
- **Exceptions**: apps and window titles to leave alone, apps that keep the focus, and the modifier
  key that suspends AutoRaise while held. "Choose Application…" fills in names for you.
- **Advanced**: hit testing, activation method, timing, live reload, verbose logging, a diagnostics
  report to paste into bug reports, and reset.
- **Statistics**: how many clicks hovering has saved you, the last two weeks day by day, and
  which applications those clicks would have gone to.
- **About**: version, links, and what this installation is actually doing.

### Statistics

Every window AutoRaise raises or focuses because you hovered it is a click you did not make, and the
Statistics page counts them. A hover acted on several times over, which is how apps that ignore the
first attempt are convinced, counts once.

The figures live in `~/.config/AutoRaise/stats.json`, written at most once a minute and again on
quit, so counting costs an increment rather than a write. Nothing leaves the machine: there is no
network code in AutoRaise at all. Pointer warps are counted separately, in warps and in the distance
the pointer skipped, because a warp saves travel rather than a click. Reset is on the page.

### The settings file

The window is a front end for a plain text file, so both work and neither wins. AutoRaise reads
`~/.AutoRaise` or `~/.config/AutoRaise/config`, then applies any command line arguments on top.
Editing the file applies immediately too, and the window only rewrites the lines it has to: your
comments, ordering and any settings a future version adds are left alone.

    # What hovering does, and how readily
    mode=raise               # raise, focusThenRaise, or focus
    eagerness=normal         # instant, quick, normal or relaxed
    raiseAfter=400           # ms, only used by focusThenRaise

    # Mouse warping on a window switch. Both factors are needed. Any switcher
    # works: a hotkey followed by an application coming forward is the signal,
    # so nothing has to be configured for a third party one.
    warpX=0.5
    warpY=0.1
    scale=2.5                # briefly enlarge the cursor after warping, 1.0 disables

    selfRaisingApps=focus    # focus, quiet or skip; see below
    ignoreSpaceChanged=false # do not act right after a space change
    typingGrace=700          # ms after a keystroke to leave the keyboard alone

    # Suspending
    disableKey=control       # control, option, command, shift or disabled
                             # a ! in front holds to allow instead: !control

    # Window titles to leave alone: ICU regular expressions, a literal comma
    # escaped as \,  Per-application behaviour lives in apps.json, below.
    ignoreTitles="^window$,\s\| Microsoft Teams"

    # The older form of the same thing, still read
    ignoreApps="IntelliJ IDEA,com.jetbrains.WebStorm"
    stayFocusedBundleIds="com.apple.SecurityAgent"

    # Behaviour that used to need recompiling
    windowServerHitTest=true # ask the window server which window is hovered
    legacyActivation=false   # activate the pre-10.15 way, for GTK, SDL and wine apps

    menuBarIcon=true
    liveReload=true
    verbose=false

    # Outline the window that has the keyboard but was not raised.
    focusRing=true
    focusRingColor=accent    # a hex colour such as #0A84FF, or accent
    focusRingStyle=outline   # outline, inline, or top, bottom, left, right for a bar
    focusRingWidth=2         # the crisp line, or how deep a bar reaches, in points
    focusRingGlow=7          # soft spread beyond it, 0 for a plain line
    focusRingRadius=11       # corner radius, and the rounding of a bar's ends
    focusRingOpacity=1.0     # at its brightest
    focusRingPulse=1.1       # seconds per breath, 0 to hold steady
    focusRingSpread=0.6      # bars: how much of the edge they cover
    focusRingFalloff=0.7     # bars: 0 cuts off at the ends, 1 fades the whole way

    # Set by the window; all of these survive a restart.
    enabled=true
    toggleShortcut=control-option-J   # pause and resume from anywhere
    raiseShortcut=control-option-R    # raise the outlined window
    returnShortcut=control-option-B   # back to the window you came from

The same names work as arguments, and `-key value` and `-key=value` are both accepted:

    ./AutoRaise -mode focus -warpX 0.5 -warpY 0.1 -ignoreApps "Xcode"

Unknown settings and malformed lines are reported at startup instead of being ignored, with the line
number. Run `./AutoRaise -help` for the full list.

Arguments beat the file, which would otherwise make a setting in the window look broken. Changing
that setting in the window drops the argument, so the window always wins from then on.

### One table, not nine lists

How an application should be treated is one question, so it has one answer:
`~/.config/AutoRaise/apps.json`, which the Exceptions page writes for you.

    [
      {"app": "com.apple.Terminal", "policy": "focus"},
      {"app": "com.jetbrains.WebStorm", "policy": "ignore"},
      {"app": "company.thebrowser.dia", "policy": "default",
       "learned": true, "raisesItself": true}
    ]

`app` matches a bundle identifier or a localized name, case insensitively, and `*` matches every
application no other line names. The policies:

| policy | what hovering does |
| --- | --- |
| `default` | whatever `mode` says; this line is only carrying what AutoRaise learned |
| `raise` | bring its windows forward |
| `focus` | hand them the keyboard where they stand |
| `quiet` | focus the application without the events it reacts to, so it stays put |
| `ignore` | nothing at all |
| `keepFocus` | while it is in front, hovering anything else changes nothing |

A line naming an application beats `*`, and both beat every general setting. An allow list is
therefore `{"app": "*", "policy": "ignore"}` plus a line per application you do want, which is what
`invertIgnoreApps` used to mean.

The `learned` lines are AutoRaise's own notes, not yours. It watches what an application does when it
is focused, writes down what it finds, and acts on it next time; `raisesItself` means the application
came forward by itself, `needsLegacyActivation` that it ignored the modern way of being activated.
Forget them from the Exceptions page and it will work them out again. Your own lines are untouched by
that.

`ignoreApps` and `stayFocusedBundleIds` in the settings file are still read. `invertIgnoreApps` is
not: the first time this version finds no `apps.json` it turns all three into lines here, and an
inverted list becomes the `*` line.

### Typing is intent too

While you are typing you are not asking to change windows, but a nudge of the trackpad used to be
enough to move the keyboard somewhere else and lose the next few characters. Hovering now waits
`typingGrace` milliseconds after your last keystroke, 700 by default, and `typingGrace=0` turns that
off.

Following the pointer also costs you the idea of where you just were, so `returnShortcut` goes back
to the window the keyboard was on before this one. Press it twice and you are back where you started.

### There is no delay to tune

A pointer crossing a window on its way somewhere else and a pointer arriving at one look identical
if all you know is where it is. That is why this used to need a delay, a dead zone and a stop
requirement: three numbers approximating one idea.

Speed tells them apart on its own. AutoRaise watches how fast the pointer is moving, and acts when it
slows to a halt on a window. Sweep across three windows at any speed and none of them move; stop on
one and it comes forward. Measured: a 1500 pt/s sweep across two windows produces nothing, and
stopping produces one action.

So `eagerness` is the only timing setting, and it says how much the pointer has to slow down before
AutoRaise believes it has arrived:

    eagerness=instant    # settles under 1200 pt/s, no hold
    eagerness=quick      # under 600 pt/s, held for 20ms
    eagerness=normal     # under 260 pt/s, held for 60ms
    eagerness=relaxed    # under 90 pt/s, held for 180ms

`pollMillis`, `heartbeatMillis`, `delay`, `focusDelay`, `mouseDelta` and `requireMouseStop` are gone.
A settings file that still has them is read once, translated into a mode and an eagerness, and told
so at startup, so nothing breaks and nothing is silently ignored.

### Focus first

`mode=focus` gives the hovered window the keyboard without raising it, and `mode=focusThenRaise`
raises it `raiseAfter` milliseconds later. Hover a chat window, a terminal or a notes window that is
partly covered and type into it, with the windows staying exactly where they are.

Because nothing moves, a focused window is otherwise indistinguishable from an unfocused one, so
AutoRaise draws a pulsing outline around the one holding the keyboard, and `raiseShortcut` brings
that window to the front when you do want it in front after all. The outline disappears as soon as
you click, focus something else, or raise it.

The highlight can trace the whole window or glow along one edge of it:

- `outline` traces around the window, `inline` just inside its edge. A window filling its display
  is drawn inline whatever the setting says, because there is no room around it.
- `top`, `bottom`, `left` and `right` draw a single bar along that edge, solid in the middle and
  fading out towards its ends. `focusRingSpread` sets how much of the edge it covers and
  `focusRingFalloff` how gently it fades: 0 cuts off, 1 fades across the whole bar. For a bar,
  `focusRingWidth` is how far the solid part reaches in from the edge and `focusRingGlow` how far
  the soft part carries on.

Either way it is clipped to the part of the window you can actually see: a window in front of the
highlighted one hides that stretch of it, instead of it being painted over the top. It follows the
window as it is moved or resized, and re-checks what is covering it four times a second while it is
on screen. Colour, brightness, corner rounding and how fast it breathes are all settings, and the
colour takes a hex value or `accent` to follow the system.

It works through undocumented SkyLight calls, so treat it as experimental: **there is no guarantee
it keeps working in future macOS versions**. It used to require a separate build with
`EXPERIMENTAL_FOCUS_FIRST`; now it is just a setting.

### One gesture, one result

Hovering a window hands it the keyboard, whatever else is on screen:

- A small window from another app sitting on top of a big one no longer makes the big one
  unhoverable. That rule only applies within a single app, where the window on top is usually a
  dialog belonging to the window underneath.
- A window that refuses the raise request is activated anyway, so it still takes the keyboard rather
  than appearing to ignore you.
- A floating window, which cannot be focused without being raised, is raised instead of skipped.
- A system dialog, a password prompt for instance, never loses the keyboard to a hover.

### Applications that raise themselves

Browsers, and a few editors, come to the front the instant they are focused.
Focusing a particular window means posting events into the application to say which window should
take the keyboard, and those events are exactly what such an application reacts to. Measured on Dia:
with them the right window becomes key and the application jumps to the front; without them it stays
put. Setting the accessibility focus attribute instead is accepted and ignored, and putting the other
windows back on top afterwards loses the race and flickers.

So `selfRaisingApps` picks which compromise you want, for the applications in the
`appsRaisingOnFocus` quirk:

    selfRaisingApps=focus    # focus the hovered window properly, and it comes forward
    selfRaisingApps=quiet    # hand it the keyboard without those events: it stays put,
                             # and it chooses which of its own windows takes the keyboard
    selfRaisingApps=skip     # do not touch it at all

`quiet` is what you want if a browser jumping in front of a chat window is the thing that annoys you.
It suits one window per screen better than several, since with several the browser decides which one
you are typing into.

### App quirks

Some apps need special handling: they leave their main window untitled, they raise themselves when
focused, or their menu bar overlay looks like a window. That knowledge lives in data rather than in
the binary. Print the built-in list with:

    ./AutoRaise -dumpQuirks

To add to it, write `~/.config/AutoRaise/quirks.json` with the same keys. Your entries are appended
to the built-ins, or replace them if you set `"replaceDefaults": true`. Keys starting with `//` are
treated as comments. `quirks.json` in this repository is an empty template.

If you work out a quirk for an app, a three line diff to the defaults is a welcome pull request.

Quirks are shipped knowledge about applications in general; `apps.json` is what you and this machine
have decided. When AutoRaise notices something itself it writes it there, not into the quirks.

## Two binaries

    AutoRaise        command line version, logs to the terminal
    AutoRaise.app    the same program, for double clicking

Both read the same settings file, both show the menu bar icon, and both open the same settings
window. Only `AutoRaise.app` can register as a login item.

## Troubleshooting

Start with `AutoRaise -probe`. It reports which window is under the mouse, according to both the
window server and the accessibility API, and whether AutoRaise considers it worth raising. That
separates "AutoRaise cannot see the window" from "AutoRaise decided against it".

    $ ./AutoRaise -probe

    Mouse at (1451, 408)
    Display (0, 0) 1512x982, menu bar 37

    Window server hit test:
      window 227 of Safari (pid 685, com.apple.Safari)
      title: Example
      frame: (0, 38) 1512x944
      main: yes, dialog: no, floating: no, full screen: no
      counts as a main window: yes

For a running instance, turn on Verbose Logging in Settings under Advanced, or start it with
`-verbose true`. The same page has a Copy button that puts everything worth reporting on the
clipboard.

Other things worth checking:

- Are you running two copies? Look for AutoRaise in Activity Monitor.
- Is another mouse tool fighting over the same windows?
- Does an app refuse to raise? Try `legacyActivation=true`, which helps apps built on GTK, SDL and
  wine.
- Does the wrong window raise? Try `windowServerHitTest=false` to use the accessibility API for hit
  testing instead, and please report it.

Accessibility permission is tied to the code signature. Signed builds keep the permission across
updates. If you build unsigned copies yourself and macOS keeps forgetting the grant, remove the stale
AutoRaise entry in System Settings, Privacy & Security, Accessibility with the minus button, then
start AutoRaise again.

## Building

    make            # AutoRaise and AutoRaise.app
    make test       # the decision logic, no accessibility permission needed
    make install    # copy AutoRaise.app to /Applications
    make icon       # redraw AutoRaise.icns from tools/make-icon.mm
    make dmg        # package a disk image

There are no compile time options left. `make` picks the best code signing certificate it can find,
preferring a Developer ID over a development certificate over ad hoc signing; override it with
`make CODESIGN_IDENTITY="Developer ID Application: You (TEAMID)"`. Check what it found with
`make identity`.

For a release, sign with a Developer ID and notarize:

    xcrun notarytool store-credentials AutoRaise --apple-id you@example.com --team-id TEAMID --password app-specific-password
    make notarize AR_NOTARY_PROFILE=AutoRaise

## How it is put together

    src/main.mm          the run loop: event tap, timers, notifications, raising
    src/Policy.mm        which window deserves raising, as pure functions
    src/WindowFinder.mm  the accessibility API and the window server
    src/Config.mm        settings, from defaults through file to arguments
    src/Quirks.mm        per app knowledge, built in and user supplied
    src/MenuBar.mm       the status item
    src/SettingsWindow.mm  the settings window and its six pages
    src/SettingsUI.mm      the controls it is built from
    src/Shortcut.mm        the global pause shortcut
    tests/               the decision logic under test
    tools/make-icon.mm   the app icon, drawn in code

`Policy.mm` never calls the accessibility API. It answers questions about facts gathered elsewhere,
which is why `make test` can exercise every accumulated app quirk without a desktop or a permission
prompt. Anything you change about which windows raise belongs there, with a test.

AutoRaise does not poll. An event tap reports mouse movement, which arms an evaluation timer that
stands down again once the mouse settles. Every accessibility request carries a short timeout, so an
unresponsive app under the cursor cannot stall AutoRaise.

## License

GNU General Public License v2 or later, see LICENSE.md. Some pieces are based on metamove by jmgao as
part of XFree86, and the focus-first code comes from [yabai](https://github.com/koekeishiya/yabai).

Dimentium maintains a homebrew formula: https://github.com/Dimentium/homebrew-autoraise
