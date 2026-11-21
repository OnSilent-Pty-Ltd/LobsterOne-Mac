# Security

## Reporting a problem

Please report security problems privately, not in a public issue.

- On GitHub, use **Report a vulnerability** on this repository's Security tab.
- Or email **support@lobsterone.ai** with "Security" in the subject.

Tell us what you found, how to reproduce it, and which version of the app you were running (Settings shows it). We will reply within five working days, keep you told as we fix it, and credit you in the release notes if you want.

## What counts

Anything that lets someone read, change or send data they shouldn't through the Mac app. For example:

- the app sending something this repository's [PRIVACY.md](PRIVACY.md) says it doesn't
- a way to get the app to run code or write files outside what it is meant to touch
- a weakness in how the app stores or handles keys and tokens
- a way to push a tampered update to users

Problems with lobsterone.ai or its API are welcome at the same address.

## Supported versions

Only the latest release gets fixes. The app checks for updates every hour and installs them itself.

## How updates are protected

Every release is signed with OnSilent Pty Ltd's Developer ID, notarised by Apple, and signed again with an EdDSA key for the in-app updater (Sparkle). The app refuses an update whose signature doesn't match the public key in its `Info.plist`.
