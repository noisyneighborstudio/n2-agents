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
under the switch says whether it was reached.

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

The bar can't be reached, rejects the secret, or refuses a draw during a BUSY
focus session: the failure is appended to `~/.n2-agents/busybar.log` and the
app carries on. Each request times out after 3 s, and a sequence stops at its
first failure.

Device facts this relies on (API 27.5.0): a draw adds to the screen, so each
card clears the app's elements first; element timeouts are whole seconds, so
the intro is one draw per 50 ms frame; elements are mounted hidden in z-order
before anything moves, since one added mid-sequence draws on top for a frame.
