# chrome-router

A tiny macOS "default browser" that opens each link in the right Chrome profile.
Click a GitHub link in Slack and it opens in your Work profile, click a YouTube
link in Mail and it opens in Personal.

- One ~200 KB native binary, no dependencies, no Electron, no menu bar icon.
- Rules live in a small JSON file. Edit them in a settings window or from the CLI.
- Match on domain, path, a regex, or the app the link was clicked in.
- Works with Chrome, Chrome Beta/Dev/Canary, Chromium, Brave and Edge.

## Install

Needs macOS 13+ and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/Dhruv9449/chrome-router.git
cd chrome-router
make install                    # → ~/Applications/Chrome Router.app + ~/.local/bin/chrome-router
chrome-router ui                # add rules, then click "Make default"
```

If `~/.local/bin` isn't on your `PATH`, add it, or install the CLI elsewhere with
`make install BIN_DIR=/usr/local/bin`.

## Configure

### Settings window

Open **Chrome Router** from Spotlight or Finder, or run `chrome-router ui`. The
window lets you:

- pick the browser and the profile for links no rule matches
- add, edit, delete and drag-reorder rules, choosing the profile from a menu of
  your real profiles and the "from" app from a menu of running apps
- try a URL and see live which profile it would open in (before saving)
- make Chrome Router the default browser

Invalid rules (empty pattern, bad regex) are flagged inline and block saving.
Closing the window leaves the app running in the background with no Dock icon.

### CLI

```sh
chrome-router profiles
# DIRECTORY  NAME / EMAIL
# Default    Personal  <me@gmail.com>
# Profile 1  Work      <me@mycompany.com>

chrome-router default Personal
chrome-router add '*.mycompany.com' Work
chrome-router add github.com/mycompany Work
chrome-router add Work --from Slack          # everything clicked in Slack
chrome-router add '^https://docs\.google\.com/.*/d/1AbC' Work --regex

chrome-router rules
#   1. match *.mycompany.com  →  Work [Profile 1, me@mycompany.com]
#   2. match github.com/mycompany  →  Work [Profile 1, me@mycompany.com]
#   ...
#   default  →  Personal [Default, me@gmail.com]

chrome-router test https://github.com/mycompany/api/pull/42
# Work [Profile 1, me@mycompany.com]  via rule #2: match github.com/mycompany
```

Rules are checked top to bottom and the first match wins. Use `move` to reorder,
`remove` to delete, `edit` to open the JSON in `$EDITOR`. Changes apply to the
next click; nothing needs restarting.

A profile can be named by its display name, its signed-in email, or its
directory (`Default`, `Profile 1`, ...).

### Rule fields

Each rule needs a `profile` and at least one condition. All conditions on a rule
must match.

| Field   | Meaning |
|---------|---------|
| `match` | Glob on the URL without the scheme. No `/` means host only: `*.mycompany.com` matches `mycompany.com` and every subdomain, `notion.so` matches only `notion.so`. With a `/` it is matched against host + path + query, and `github.com/mycompany` also covers everything under it (but not `github.com/mycompany-fork`). Case-insensitive. |
| `regex` | Case-insensitive regular expression searched in the full URL. |
| `from`  | The app the link was clicked in, by name (`Slack`) or bundle id (`com.tinyspeck.slackmacgap`). |

Top-level fields: `default` is the profile for unmatched links (leave it out to
let Chrome use its last-used profile), `browser` is one of `chrome`,
`chrome-beta`, `chrome-dev`, `chrome-canary`, `chromium`, `brave`, `edge`.

See [config.example.json](config.example.json).

## How it works

`Chrome Router.app` is a background app (no Dock icon) registered for `http`
and `https`. Launching it yourself shows the settings window; launches caused
by a link click don't. When macOS hands it a link, it reloads the config, picks a
profile, and starts the browser with `--profile-directory=<dir> <url>`. If the
browser is already running, that hands the URL to the existing window and
exits. The clicking app is read from the sender of the open-URL Apple Event.

Profiles are read from the browser's `Local State` file, e.g.
`~/Library/Application Support/Google/Chrome/Local State`.

Every routed link is logged to `~/Library/Logs/chrome-router.log`.
`chrome-router status` shows paths and whether it is the default browser.

## Develop

```sh
make build   # build/chrome-router
make test    # CLI tests against a fake config and Local State
make app     # build/Chrome Router.app
```

## Uninstall

```sh
make uninstall
```

Then pick another default browser in System Settings → Desktop & Dock.
