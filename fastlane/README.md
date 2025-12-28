fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios build

```sh
[bundle exec] fastlane ios build
```

Build the app without uploading (for testing)

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Deploy to TestFlight

Usage: fastlane beta [build_number:XX] [changelog:'Notes']

### ios release

```sh
[bundle exec] fastlane ios release
```

Submit to the App Store for review

Usage: fastlane release [submit:true]

### ios download_metadata

```sh
[bundle exec] fastlane ios download_metadata
```

Download current metadata from App Store Connect

### ios upload_metadata

```sh
[bundle exec] fastlane ios upload_metadata
```

Upload metadata without submitting a build

### ios bump

```sh
[bundle exec] fastlane ios bump
```

Increment version number (major, minor, patch)

### ios version_info

```sh
[bundle exec] fastlane ios version_info
```

Display current version information

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
