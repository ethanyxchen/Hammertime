# Hammertime

A native macOS menu bar app for tracking the pull requests you merge, across personal projects and work repositories.

Set daily, weekly, and monthly targets for personal work and each organisation. Connect multiple GitHub accounts, choose entire repository owners or individual repositories, and see your progress against them.

## Install

Requires macOS 26 or newer.

```sh
brew install --cask ethanyxchen/tap/hammertime
```

Hammertime checks for updates itself and installs them from **Settings** or the **Check for Updates…** menu item.

## Connect GitHub

Hammertime connects through [GitHub CLI](https://cli.github.com). Install it and sign in once:

```sh
brew install gh
gh auth login
```

Then choose **Connect GitHub** in Hammertime and click **Connect**. Hammertime links the account GitHub CLI is signed in to, with the same permissions. Its credential is saved in macOS Keychain. GitHub CLI's default sign in includes private repositories; organizations may require approval or SSO authorization before their private activity is accessible.

To add another account, run `gh auth login` for it, which also makes it GitHub CLI's active account, then connect again in Hammertime. Connecting the same account again updates its credential and activity while keeping its name and repository selections. Reconnect or disconnect from **Targets & Accounts**. Disconnecting removes Hammertime's copy of the credential; GitHub CLI stays signed in.

## Sync settings

Targets, workspace colours, pinned and renamed organisations, and repository selections sync through a secret gist named `hammertime.json` on the first connected account. Connect that account on another Mac and its settings arrive; changes on either Mac reach the other within a minute. When a Mac syncs for the first time, the gist's settings replace its own. GitHub CLI's default sign in includes gist access; if yours does not, run `gh auth refresh -s gist` and reconnect.

## Credits

- ["Sledgehammer"](https://sketchfab.com/3d-models/sledgehammer-8194ce123fd64429b183c26df7fba17e) by Yaroslav Lazun, licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- ["Studio Small 09"](https://polyhaven.com/a/studio_small_09) HDRI from Poly Haven, licensed under CC0.
- ["Glass Shatter 1"](https://freesound.org/people/Greg_Surr/sounds/554565/) by Greg_Surr, licensed under CC0.
- ["Sound Design Elements Impact SFX PS 089"](https://freesound.org/people/AudioPapkin/sounds/814883/) by AudioPapkin, licensed under CC0.
