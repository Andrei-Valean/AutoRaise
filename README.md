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
- **Pointer**: mouse warping on window switch. Drag the pointer around a small window to say where
  it should land.
- **Exceptions**: apps and window titles to leave alone, apps that keep the focus, and the modifier
  key that suspends AutoRaise while held. "Choose Application…" fills in names for you.
- **Advanced**: hit testing, activation method, timing, live reload, verbose logging, a diagnostics
  report to paste into bug reports, and reset.
- **About**: version, links, and what this installation is actually doing.

### The settings file

The window is a front end for a plain text file, so both work and neither wins. AutoRaise reads
`~/.AutoRaise` or `~/.config/AutoRaise/config`, then applies any command line arguments on top.
Editing the file applies immediately too, and the window only rewrites the lines it has to: your
comments, ordering and any settings a future version adds are left alone.

    # Timing
    pollMillis=50            # how often to re-evaluate while the mouse moves
    heartbeatMillis=500      # idle safety net, 0 disables it
    delay=1                  # raise delay: 0 never raises, 1 raises at once, n waits (n-1) * pollMillis
    focusDelay=0             # focus first and raise this much later, 0 disables

    # Mouse warping on cmd-tab and cmd-grave. Both factors are needed.
    warpX=0.5
    warpY=0.1
    scale=2.5                # briefly enlarge the cursor after warping, 1.0 disables
    altTaskSwitcher=false    # set when you use a third party task switcher

    # Sensitivity
    requireMouseStop=true    # wait for the mouse to stop before acting
    mouseDelta=0.0           # ignore movements smaller than this
    ignoreSpaceChanged=false # do not act right after a space change

    # Suspending
    disableKey=control       # control, option, command, shift or disabled
    invertDisableKey=false   # hold the key to enable instead of disable

    # Exceptions. App entries match a localized name or a bundle identifier;
    # titles are ICU regular expressions. Escape a literal comma as \,
    ignoreApps="IntelliJ IDEA,com.jetbrains.WebStorm"
    ignoreTitles="^window$,\s\| Microsoft Teams"
    invertIgnoreApps=false   # turn ignoreApps into an allow list
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

    # Set by the window; all of these survive a restart.
    enabled=true
    toggleShortcut=control-option-J   # pause and resume from anywhere
    raiseShortcut=control-option-R    # raise the outlined window

The same names work as arguments, and `-key value` and `-key=value` are both accepted:

    ./AutoRaise -delay 2 -warpX 0.5 -warpY 0.1 -ignoreApps "Xcode"

Unknown settings and malformed lines are reported at startup instead of being ignored, with the line
number. Run `./AutoRaise -help` for the full list.

Arguments beat the file, which would otherwise make a setting in the window look broken. Changing
that setting in the window drops the argument, so the window always wins from then on.

### Focus first

`focusDelay` focuses the hovered window without raising it, and raises it `delay` evaluations later,
or never when `delay=0`. Hover a chat window, a terminal or a notes window that is partly covered
and type into it, with the windows staying exactly where they are.

Because nothing moves, a focused window is otherwise indistinguishable from an unfocused one, so
AutoRaise draws a pulsing outline around the one holding the keyboard. `focusRingColor` takes a hex
colour or `accent` to follow the system, and `raiseShortcut` brings the outlined window to the front
when you do want it in front after all. The outline disappears as soon as you click, focus something
else, or raise it.

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

### App quirks

Some apps need special handling: they leave their main window untitled, they raise themselves when
focused, or their menu bar overlay looks like a window. That knowledge lives in data rather than in
the binary. Print the built-in list with:

    ./AutoRaise -dumpQuirks

To add to it, write `~/.config/AutoRaise/quirks.json` with the same keys. Your entries are appended
to the built-ins, or replace them if you set `"replaceDefaults": true`. Keys starting with `//` are
treated as comments. `quirks.json` in this repository is an empty template.

If you work out a quirk for an app, a three line diff to the defaults is a welcome pull request.

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
