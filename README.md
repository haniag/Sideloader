# Sideloader

A macOS app for installing already-signed `.ipa` files on iPhones and iPads: choose an IPA, choose a device, watch it install.

## Installers

| Installer | Needs | Connections |
| --- | --- | --- |
| **devicectl** (default when Xcode is installed) | Xcode | USB and Wi-Fi paired devices |
| **libimobiledevice** (fallback, bundled in the app) | nothing | USB |

Switch between them from the toolbar menu or in Settings (⌘,). **Automatic** picks devicectl when Xcode is found, otherwise libimobiledevice.

## Keeping libimobiledevice up to date

The app bundles libimobiledevice and its dependencies from Homebrew (`Vendor/libimobiledevice`):

```sh
Scripts/update-libimobiledevice.sh              # brew upgrade, then re-vendor
Scripts/update-libimobiledevice.sh --no-upgrade # re-vendor what Homebrew already has
```

Then rebuild. Every build warns when Homebrew has a newer version than the bundled one, and Settings › libimobiledevice compares the bundled versions with the latest upstream tags on GitHub.

The bundled libraries match the Homebrew bottles: currently arm64 only and macOS 26 or later (see `Vendor/libimobiledevice/manifest.json`). On older or Intel Macs the app still runs with devicectl only.

## Notes

- The App Sandbox is off: the app runs `devicectl` and talks to `usbmuxd`.
- The device must be in the app's provisioning profile, and Developer Mode must be on for development-signed apps. The app warns about both before installing.
