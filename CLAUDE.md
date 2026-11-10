# Daymark

iOS journal app (Xcode project `daymark.xcodeproj`, scheme `daymark`). Personal project.

## Rules

- Build and test with `scripts/build.sh` (`test`, `install`, `all`). It targets the paired iPhone, never the simulator, and always shuts down simulators and deletes its build intermediates when it exits.
- Commits have no `Co-Authored-By` or `Claude-Session` trailers.
- New branches are named `feature/attopos/<short-description>`, e.g. `feature/attopos/model-team-filter`.
- No pull requests: once the build and tests pass on the Mac, merge into `main` and push.
- Never commit `posters/`.
