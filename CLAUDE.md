# Launching the app

When launching Hammertime for testing, build it with `./scripts/build-app.sh` and always launch it in the background with `open -g -j build/Hammertime.app --args --no-activate` so it never takes focus from other windows. Hammertime is a menu bar app with no Dock icon; its window opens at launch only when no GitHub account is connected, and otherwise when Hammertime is opened again while running. `--no-activate` stops the app from bringing itself to the foreground at launch. Never run the executable inside the bundle directly, and never launch it through Xcode's Run; both bring the app to the foreground.

The one exception is `./scripts/replay-slam.sh`, which replays the merge celebration for someone to watch. It relaunches Hammertime in the background and then opens its window in the foreground so the slam plays there; with `--banner` it leaves the window closed so the slam plays on the floating card instead. Run it only when the user asks to see the celebration.

# Compiler warnings

The build must stay free of compiler warnings. The pre-commit hook in `.githooks/pre-commit` compiles with warnings treated as errors and blocks the commit when any appear; enable it once per clone with `git config core.hooksPath .githooks`. Whenever a build, `./scripts/build-app.sh`, or the hook reports a warning, fix its cause in the code right away, even when the warning is in code you did not touch. Never silence a warning, suppress a diagnostic, or bypass the hook with `--no-verify`.

# Versioning

Releases are tagged `vMAJOR.MINOR.PATCH` on `main`, and the tag sets the app's version. The patch number's parity says what a release ships: even for a feature release, odd for a release of only bug fixes. Tag the next release with the smallest patch number above the latest tag that has the right parity: from `v1.2.1`, a feature release is `v1.2.2` and a bug-fix release is `v1.2.3`; from `v1.2.2`, a feature release is `v1.2.4` and a bug-fix release is `v1.2.3`. Never bump the minor or major number yourself; those upgrades are made only by the owner.
