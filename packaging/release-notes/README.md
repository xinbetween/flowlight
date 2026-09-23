# Release notes

One file per version, named `<version>.md` — `0.2.2.md` for the tag `v0.2.2`. The release workflow uses it as the
body of the GitHub release and appends the checksums, which it only knows once the artifacts are built. Without a
file for the version, the release falls back to GitHub's generated notes.

The same text usually belongs in `site/pages/releases.html`, which is what the website shows.
