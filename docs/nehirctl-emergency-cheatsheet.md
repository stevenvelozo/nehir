---
title: nehirctl Emergency Cheatsheet
---

# nehirctl Emergency Cheatsheet

For when Nehir wedges — input capture (can't click other windows), stuck focus, windows not being
picked up, a broken state after FaceTime / screen sharing, etc.

**The one thing to know:** `nehirctl` talks to Nehir over its **IPC socket, which is independent of
the event/input tap**. So it keeps answering even when the tap has your clicks hostage — including
**over SSH from another machine**. That means you can *capture the broken state* and *recover*
without resorting to `kill -HUP`.

`nehirctl` lives at `~/.local/bin/nehirctl`. Over SSH, use the full path if it's not on `PATH`.

---

## 1. Capture first — before you recover

The state vanishes the moment you restart, so grab it **first**. One command does it all:

```bash
~/Code/retold/modules/private/nehir/packaging/capture-debug-state.sh
```

That writes `~/nehir-debug-<timestamp>/` with the reconcile snapshot + trace buffer, all the window
/ focus / display state, `runtime-state.json`, and any trace files. Zip that folder up for later.

If you don't have the script handy, the single most useful grab is the reconcile snapshot (it
carries both the live state **and** the recent event trace ring buffer):

```bash
nehirctl query reconcile-debug --format text > ~/nehir-wedge.txt
```

Handy supporting grabs:

```bash
nehirctl query windows                  # every managed window + mode/visibility/hidden phase
nehirctl query focused-window           # what Nehir thinks is focused
nehirctl query focused-window-decision  # WHY focus landed where it did
nehirctl command debug dump-runtime-state   # dumps to the clipboard + unified log
```

---

## 2. Recover control — lightest to nuclear

Try these in order; stop when you get control back.

```bash
# a) Rebootstrap runtime state in place — NO relaunch, no re-tiling churn. Clears a wedged
#    focus lease / reconcile state. Try this first.
nehirctl command debug reset-runtime-state

# b) One stuck window (floored / fixed / holding input): reset just that window's tracked state.
nehirctl command debug reset-focused-window-runtime

# c) Relaunch Nehir with a clean slate — re-installs the event tap, so this fixes a wedged tap
#    (the "can't click anything" case). The IPC connection drops as it relaunches; a
#    "Connection reset by peer" here is EXPECTED, not a failure.
nehirctl command debug restart-clearing-runtime-state

# d) Last resort, from SSH if even IPC is unresponsive — kill Nehir; it removes its event tap so
#    clicks work again, then reopen it.
pkill -x Nehir            # or: kill -HUP <pid>   (pgrep -x Nehir to find the pid)
```

Prefer **(c)** over **(d)** whenever IPC still answers — it relaunches cleanly instead of leaving
Nehir dead until you reopen it.

---

## 3. Trace a reproducible wedge

When a bug is reproducible, capture a full event trace of it happening:

```bash
nehirctl command debug trace toggle active   # start live tracing
#   ... reproduce the wedge ...
nehirctl command debug capture-recent-trace  # flush the buffer to ~/.local/state/nehir/traces/
nehirctl command debug trace toggle inactive # stop tracing
```

Traces land in `~/.local/state/nehir/traces/runtime-trace-<start>-<end>.log`. Grab the newest one
alongside the capture folder from step 1.

---

## 4. Quick inspection (no capture, just look)

```bash
nehirctl query windows --format table          # readable window list
nehirctl query displays                        # monitors + visible frames
nehirctl query workspaces                       # workspaces + window counts
nehirctl query rules                            # active app rules
nehirctl ping                                   # is Nehir's IPC alive at all?
```

Full command/query list: run `nehirctl` with no arguments, or `nehirctl help`.

---

## What to hand over for a fix

When something wedges and you want it fixed later, the useful bundle is: the
`nehir-debug-<timestamp>/` folder (step 1), the newest trace log (step 3 if you managed to trace
it), and a one-line note of **what you were doing** when it wedged (e.g. "started screen sharing
while a FaceTime call was up"). The reconcile snapshot's `focus-lease`, `non-managed-focus`, and any
window stuck in a hidden phase are usually where the story is.
