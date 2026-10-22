# Leonera Paper: instructions for Claude

## Language

- Write code comments in English.
- Write Markdown files (this file, README, docs) in English.
- Name classes, structs, enums, functions, methods, properties and instances in English.
- This rule covers only the items above. User-facing strings (UI labels, messages) are not changed by it.
- Existing code is mostly in Spanish. Do not translate existing comments, names or Markdown unless the user asks for it.

## Build name in summaries

- When you finish a task and write a summary of the changes, include the build name that carries them, for example `build-30-1bca82e`.
- Branch builds are named `build-<run>-<sha7>`:
  - `<run>` is the GitHub Actions run number of the Build workflow (`.github/workflows/build.yml`).
  - `<sha7>` is the first 7 characters of the commit SHA (`git rev-parse HEAD | cut -c1-7`).
- Builds on `main` are named `0.<n>.0` instead.
- The run number exists only after CI runs. If it is not known yet, give `sha7` and say that the run number is pending.

## Build label in the app

- The workflow passes the build name to xcodebuild as `LP_BUILD_TAG`.
- `Config/App-Info.plist` exposes it as `LPBuildTag`.
- Settings shows it in «Acerca de» › «Build».
- Keep these three in sync. Local builds show `local`.
