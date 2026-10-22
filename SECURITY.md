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

## Official rule-pack feed

The official rule-pack catalog is signed separately with an offline P-256 key. The repository and deployment
workflows contain only its public key: CI verifies the exact catalog Pages will serve and has no ability to produce a
trusted replacement. Each catalog has an increasing sequence number, and clients do not accept a lower sequence, so
an older feed cannot be replayed as a rollback even if it is otherwise correctly signed.

Key rotation has an overlap period: an app release first trusts both keys, the feed is then signed by both, and only a
later app release removes the old public key. Revocation likewise requires an app release removing the affected key;
a signed feed cannot revoke the key that authenticates it. After rollback, expiry, or key compromise, corrected
content is published with a new higher sequence rather than changing history or reusing a sequence.

The app consumes only `https://flowlight.xinbetween.com/packs/v1/official.json`; there is no user-supplied source or
unsigned fallback. It bounds response size and redirects, verifies exact cached bytes again at launch, and keeps its
highest accepted sequence independently from those bytes so cache loss cannot authorize rollback. An already accepted
catalog may remain active after expiry as visibly stale last-known-good, but a revoked signer or unverifiable cache
fails closed until the same or a higher trusted catalog is recovered.

A valid publisher signature is not user consent. New packs default off, and any changed version or destination digest
removes that pack from enforcement while retaining its saved scope and exceptions. Re-enabling requires an explicit Save
bound to the exact catalog and pack content the editor displayed; a concurrent refresh makes the old Save stale.
