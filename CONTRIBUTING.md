# Contributing

Thanks for your interest in contributing to IINA!

## Before You Start

1. **Check the [issue tracker](https://github.com/iina/iina/issues)** to avoid duplicate work and get community input before coding.
2. **Open a Design Proposal issue** to discuss your idea:
   - **Required** for UI changes (e.g., sidebar items, toolbar buttons, layout). Including a mockup is recommended.
   - **Recommended** if the change contains other interactive elements (e.g., new preferences, dialogs) or is large (spanning multiple files, affecting multiple components).
   - **Optional** for small, self-contained fixes.
3. **Link your design proposal** in your pull request description. PRs without one (when required) may be closed without review.

By submitting a pull request,
- You give the IINA team permission to take over and modify your code at any time,
  for the sole purpose of merging it into IINA.
- You agree that your contributions are licensed under the GPLv3 license.
  In the case of a future IINA release in the App Store,
  you agree that you will not pursue any license violations that results
  solely from the conflict between the GPLv3 license and the App Store's terms of service.

## Contribution Workflow

- Follow [README.md](README.md) to set up your environment, including [downloading the pre-compiled dylibs](README.md#using-the-pre-compiled-libraries).
- Use the [latest public version of Xcode](https://itunes.apple.com/us/app/xcode/id497799835). Around June, a branch for the next macOS version may appear, but main development stays on `develop`.
- Test thoroughly, including any features that share code with your changes.
- Rebase on top of `develop` before opening your PR to avoid merge conflicts.
- Submit separate PRs for unrelated changes.
- Only include files you intentionally changed. Watch for spurious diffs in:
  - `project.pbxproj` — may change if signed with a different developer account. Changes from adding/removing files are fine.
  - `xib` files — discard changes you didn't make.

## Tests

After downloading the dependencies, run the macOS application-hosted regression tests:

```sh
./other/test_fullscreen.sh
```

These tests require a logged-in graphical macOS session. The calling terminal/application needs
Screen Recording and event-posting permissions. The script starts a separate ScreenCaptureKit probe
because the Xcode test host has its own permissions. Missing permissions or a missing probe fail
the visual test instead of silently skipping it. The probe briefly moves the system cursor and restores
its original position when finished.

The suite covers renderer lock contention, bounded redraw scheduling, fullscreen completion and
failure callbacks, mouse event bursts, and audio/video synchronization. A 60 fps test clip with a chroma
marker lets the probe find the video during the fullscreen animation. It measures frame holds using
WindowServer display timestamps and observes the cursor's actual pixels, comparing its cadence with
a static reference scene on the same display. This catches stalls that mpv's drop counter and direct
calls to `mouseMoved` cannot detect. The capture itself is calibrated; it is not a measurement of the
panel's physical scanout.

Raw frame measurements and phase timestamps are retained as JSON attachments in the Xcode test
result. For a named result bundle, pass `-resultBundlePath` and a new output path to the script.

## Localizations

We use [Crowdin](https://crowdin.com/project/iina) for localization.
You must localize any new strings, and only update strings in `Base.lproj` and `en.lproj`.
Do not include translations for languages other than English.
(New English strings on `develop` sync to Crowdin automatically, and we fetch translations before each release.)

## AI Usage

AI tools are permitted, but low-quality AI-generated code will likely be rejected. If you use AI:

- You must be responsible for confirming that the code complies with IINA's GPLv3 license.
- Disclose the AI usage in the PR description.
  Failure to do while submitting obviously AI-generated code may result in your PR being closed without review.
- Keep the PR description concise and justify your design choices.
- Test thoroughly and remove excessive comments.

## Design Guidelines and Code Conventions

- In general, follow the [macOS Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/macos/)
  and match built-in macOS app behavior.
- Use system controls with proper font weight, size, and color.
- Leave margins everywhere. Use animations where appropriate.
- Give users more choices when possible.
- Do not introduce new `xib` files, and avoid changing existing ones.
  Use the helpers in `UIHelper` (for creating common UI components) and
  `ConstraintsSugar.swift` (for setting up AutoLayout constraints) instead.
- Add comments only when necessary.
- In your Xcode settings, use 2-space indentation and remove trailing spaces automatically.
- No fixed style guide, but we may request changes for consistency with surrounding code.

## Architecture

All new code should follow these guidelines:

- Only `VideoView` and `MPVController` may call mpv APIs directly.
- `PlayerCore` encapsulates playback logic. Avoid setting options/properties directly through `MPVController`.
- Window logic belongs in `MainWindowController`:
  - `windowDidLoad()` — one-time setup.
  - `windowDidOpen()` — runs each time the window appears (e.g., resetting UI). The window may not be loaded yet.
  - `windowWillClose()` — release resources and deinitialize.
- These files are generated by `other/parse_doc.rb` and **must not** be edited directly: `MPVCommand`, `MPVOption`, `MPVProperty`.

If you think this document can be improved, please open an issue.
