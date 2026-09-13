# omarchy-notifications

A standing bell in the [Omarchy](https://omarchy.org/) bar: what arrived while
you were looking elsewhere, replayable as toasts, with do-not-disturb one
right-click away.

## Why

Omarchy's notification plugin is a service with no bar-widget entry point.
Toasts appear top-right, expire, and are archived into a history directory.
Nothing in the bar says that happened. The only stock indicator is the DND
glyph inside `omarchy.indicators`, and it is deliberately invisible unless DND
is on — so **a notification you missed and a notification that never arrived
look identical**.

This widget reads that history and counts what landed there since you last
looked.

## The count

A notification only reaches history once its toast has expired. Anything still
on screen is being seen right now and is deliberately *not* counted — the badge
is "what I missed", not "what exists". Opening the panel is reading them, so
the count clears.

On a cold start the badge is stamped to zero rather than dumping the existing
archive at you. It survives plugin hot-reloads, not a full shell restart.

## Install

```bash
omarchy plugin add https://github.com/dbarke/omarchy-notifications.git --enable
```

Or clone it into place yourself:

```bash
git clone https://github.com/dbarke/omarchy-notifications.git \
  ~/.config/omarchy/plugins/dbarke.notifications
omarchy plugin enable dbarke.notifications --section right
```

## Use

| Action | Result |
|---|---|
| Click | Open the panel |
| Right-click | Toggle do not disturb |
| `r` | Replay recent history as toasts |
| `c` | Clear history |
| `d` | Toggle do not disturb |
| `↑` `↓` | Scroll the list |

The glyph changes shape rather than only colour: `󰂚` quiet, `󰂞` something
waiting, `󰂛` silenced. Silenced always stays visible even with *Hide when
quiet* on — a hidden mute is how you miss a day of messages.

## Settings

| Setting | Default | What it does |
|---|---|---|
| Refresh interval | `15`s | A backstop only. The count already updates the moment a toast expires. |
| Show the count | on | Off leaves just the bell, which still changes shape. |
| Hide when quiet | off | Collapses the widget while nothing is unseen and nothing is silenced. |
| Body text limit | `140` | Characters of each body shown before eliding. `0` shows titles only. |
| Ignore notifications matching | `Screenshot saved` | Comma-separated text, matched case-insensitively against each notification's app name and title. Matches are dropped before anything is counted or listed. |

### About that last one

Omarchy notifies you every time you take a screenshot
(`omarchy-capture-screenshot`), and it archives like anything else — so without
a filter the badge counts a notification you triggered yourself two seconds
ago. The default pattern drops it. Empty the field to keep everything.

## Requirements

- Omarchy 4.x (`omarchy-shell` / Quickshell)
- `python3` — parses the history directory, whose payloads carry newlines and
  markup that would have to be unpicked from shell output otherwise

## License

MIT — see [LICENSE](LICENSE).
