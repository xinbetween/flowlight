# Mac App Store screenshots

These images are the reviewable source of truth for the Flowlight Mac App Store listing. They are captured from the exact App Store product—not the Developer ID product—using synthetic demo data only.

Build the Store product, then run:

```sh
FL_APP=/absolute/path/to/Flowlight.app scripts/app-store-screenshots.sh
```

The capture gate requires:

- the bundle to contain the embedded Store extension and no Developer ID system extension;
- the app version and build number to match `project.yml`;
- the requested screen title to match before capture;
- `demo.sqlite*` to be the only traffic database opened by the candidate;
- every retained image to be exactly 2880×1800 pixels;
- English and light appearance for a consistent US storefront set.

Upload the numbered files in `macos/` in filename order. The Store set uses Policies in place of Inspect because the Store product deliberately omits HTTPS inspection. Replace the complete existing App Store Connect screenshot set together; do not mix images from different builds or menu vocabularies.
