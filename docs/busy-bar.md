# BUSY Bar

N2 Agents can show lab health on a [BUSY Bar](https://busy.app), the 72×16 LED
desk display. It shows the same changes the menu bar toasts announce, for every
profile and every lab:

| Card       | When                                             | Stays            |
|------------|--------------------------------------------------|------------------|
| 50% LEFT   | a slot's allowance drops to half                 | 60 s             |
| 25% LEFT   | to a quarter                                     | 60 s             |
| 10% LEFT   | to a tenth                                       | 120 s            |
| OUT        | it runs out, or the provider refuses work        | until it's back  |
| BACK       | an exhausted slot has capacity again             | 60 s             |
| SIGNED OUT | a slot loses its sign-in                         | until signed in  |

Each card plays a short intro with the N2 mark, then shows the word over the
profile and lab (for example `Work - Codex, back Mon 3:40 PM`), and the LED
blinks in the card's color. A tier is announced once when entered; a reading
back above it makes the next dip news again. What is already so when the app
starts stays quiet. A newer card replaces the one on screen, and pressing Back
on the bar dismisses it.

N2 Agents doesn't track agent turns, so the bar shows nothing when an agent
finishes or waits on you.

## Set it up

Turn on **Settings › BUSY Bar › Send events to BUSY Bar**, or run
`agents busybar on`. Over USB that's all: the bar plays a hello, and the line
under the switch says whether it's connected. Plugging the bar in later is
fine: the app connects on its own.

For Wi-Fi or the cloud, open **Connection**, enter an address and secret, and
save. From a terminal, `agents busybar on --address <address> --token-stdin`
reads the secret from standard input.

- **Wi-Fi:** the bar's IP address and its HTTP access password. To set the
  password, connect the bar over USB, open `10.0.4.20`, and go to
  **Settings › HTTP Access**.
- **Anywhere:** `api.busy.app` and an API token from
  [cloud.busy.app](https://cloud.busy.app/api-tokens).

`agents busybar off` turns it off and clears the bar. `agents busybar status`
prints the switch and whether the bar answered.

## How it works

The menu bar app decides when (`tray/BusyBar.swift`) and calls
`agents busybar alert|clear`, one at a time in order. `busybar.py` holds the
cards, the device calls and the intro animation; the settings live in
`~/.n2-agents/busybar.json` (mode 0600). Nothing runs inside any lab or
profile config.

Device facts this relies on (API 27.5.0): a draw adds to the screen, so each
card clears the app's elements first; element timeouts are whole seconds, so
the intro is one draw per 50 ms frame; elements are mounted hidden in z-order
before anything moves, since one added mid-sequence draws on top for a frame.

## When the bar isn't there

The switch can stay on whether or not a bar is attached. Every 30 s the app
checks for it (`agents busybar sync`). A card that comes up while the bar is
unplugged, asleep, off the network, or refusing draws during a BUSY focus
session waits in `~/.n2-agents/busybar.state`. When the bar answers again, the
card goes up for whatever time it has left; OUT and SIGNED OUT stay up until
they're resolved. If nothing should be showing, any stale N2 card is cleared.
Settings shows "Not connected" until the bar answers, and refreshes every 10 s.

Each request times out after 3 s, and a sequence stops at its first failure.
`~/.n2-agents/busybar.log` gets one line when the bar drops and one when it
returns, not one per card.
