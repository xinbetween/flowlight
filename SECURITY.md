# Security

Flowlight watches what other software on a Mac sends, and with HTTPS inspection on it can read request and
response bodies. That makes a bug in it worth more than a bug in most apps, so reports are welcome and taken
seriously.

## Reporting

- **[Private vulnerability reporting](https://github.com/xinbetween/flowlight/security/advisories/new)** on
  this repository. Preferred: it keeps the report, the fix and the advisory in one place.
- **security@xinbetween.com**, if you would rather not use GitHub, or cannot.

Please don't open a public issue for something exploitable. Anything else — a crash, a wrong number, a
misleading screen — belongs in the normal issue tracker.

## What to expect

A first reply within three working days, and an honest assessment rather than a holding message: whether it
reproduces, whether it is a vulnerability or a bug, and what the fix looks like. If a report is not a
vulnerability, we will say so and why rather than leaving it in a queue.

Fixes ship in the next release, and sooner where one is warranted. You will be credited in the release notes
unless you would rather not be.

## Scope

In scope: anything that lets software on the Mac read data Flowlight holds, escape the limits stated in the
documentation, tamper with an update, or make Flowlight report something false — a connection it did not show,
an agent it attributed to the wrong process, a rule it said was enforcing when it was not.

Out of scope, because they are already true by design and documented:

- **Software running as root can switch Flowlight off.** It is a monitor, not a defence against an attacker
  who already owns the machine.
- **A content filter does not see everything.** Another filter can hold the one slot macOS offers, system
  traffic is exempt, and traffic from before capture started never existed as far as Flowlight is concerned.
- **HTTPS inspection only reads what is routed through the proxy.** An app that ignores proxy settings or pins
  its certificates is passed through untouched, by design.
- **Blocking is not prevention.** A refused connection is refused at the network layer; an agent that can run
  a shell can do by hand what the refused tool would have done.

The [threat model](https://flowlight.xinbetween.com/threat-model/) says all of this at more length, including
what Flowlight does defend against.

## Signed releases

Releases are signed with a Developer ID and notarized by Apple, and every release publishes `SHA256SUMS.txt`.
The in-app updater refuses a download whose checksum it cannot verify, and refuses to install an app that is
not signed by the same team as the copy asking for the update.
