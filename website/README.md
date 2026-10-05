# TilePilot website

Static site for https://autonomath.github.io/TilePilot/. There is no framework and no third-party runtime: fonts are self-hosted (SIL Open Font License, see `assets/fonts/OFL.txt`) and the page loads nothing from other hosts.

```bash
node website/build.mjs                          # copy and validate into website/_site
python3 -m http.server 8765 -d website/_site    # preview at http://127.0.0.1:8765/
```

`.github/workflows/pages.yml` deploys on pushes to `main` that touch `website/`, on each published release, and on manual runs. It fetches the latest release and runs `node website/build.mjs --release release.json`, so download links, the version, and the file size always match the newest DMG.

Screenshots in `assets/shots/` are window-only captures of the app, reviewed and cropped so they show no personal window titles, file paths, or running-app lists. Keep that standard when replacing them.
