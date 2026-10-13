# In-app Android updates

WorkoutApp (MorningCoach) uses the updater from SuperHealth, adapted from commit
`09c84feef339ec9cdac26e4c4b28119cfae721fc` to this app's package, language setting,
workout persistence and existing APK signing key.

Settings → **App updates** checks the latest stable release in
`gaduffl/WorkoutApp`. The launch/resume check defaults to on and runs at most once
per hour. **Auto-update** defaults to off, as in SuperHealth; turn it on in the
card to download and install newer builds automatically when Android supports
unattended self-updates. First allow this app to install unknown apps on Android's
per-app settings page. Android 11 and older, or a device whose app store owns
updates, keeps the manual confirmation path.

Automatic installation waits for startup, pending workout completion, bouldering
or travel-mode writes, OneDrive backups, and any saved unfinished workout. Every
route or dialog over Home also blocks it, including the logger and Settings with
unsaved changes. In the foreground a ten-second banner announces that Android
will close the app; **Later** postpones it. In the background a verified update
can install immediately once the blockers clear. A foreground update leaves an
Android notification to reopen the new build, when notifications are allowed.

The first APK containing the updater must be installed manually over the existing
app. Later updates use the same Android package and pinned `debug.keystore`, so
they preserve existing app data. CI continues to build debug APKs with
`github.run_number` as `versionCode`; no signing-key migration is performed.
Releases now have parseable `v1.0.0+<run_number>` tags and are stable/latest rather
than debug prereleases. CI uploads the APK to a draft before publishing it, so
the update API never advertises a release before its download exists.

The updater compares Android build numbers first, downloads only over HTTPS,
checks asset size and GitHub's SHA-256 digest when supplied, and lets Android
verify package identity and signing continuity. Redirects never forward tokens.
An optional private-repository token is stored in encrypted device storage.
Update settings and tokens stay outside workout backup/restore data.

An optional HTTPS server source uses a JSON manifest with required `version`,
`apk_url` (absolute or relative), and a 64-character hex `sha256`; `size`, `notes`
and `published_at` are optional. Its bearer token goes only to the manifest host.

The transferred regression tests cover version ordering, source validation,
download integrity/cancellation, permissions, automatic checks, countdowns,
postponement and fallback to manual installation. Workout-specific tests cover
startup, saved drafts, backup failures, routes and dialogs. GitHub Actions also
compiles the Kotlin installer and receivers in the APK build. Real-device
unattended installation remains a device check; CI does not install APKs.
