# daymark

## Build and test

```bash
scripts/build.sh            # build and install on the paired iPhone
scripts/build.sh test       # unit tests (daymarkTests) on the iPhone
scripts/build.sh all        # tests, then build and install
scripts/build.sh build      # build only
scripts/build.sh clean      # only clean up
```

The script uses the paired iPhone; pass `--simulator` to use the iOS Simulator instead (`SIM_NAME`, default "iPhone 18 Pro"). `DEVICE_ID` picks a specific device.

Every run builds into its own temporary `$TMPDIR/daymark-build.*` folder and, when it exits (success, failure or Ctrl-C), cleans up:

- deletes that build folder (after the app has been installed), plus leftover `daymark-build.*` folders in `$TMPDIR` and `/private/tmp` when no other Daymark build is running;
- deletes Daymark's folders in `~/Library/Developer/Xcode/DerivedData` (`daymark-*`, checked against this repo's path when Xcode wrote an `info.plist`) and `build/` or `DerivedData/` in the repo;
- shuts down booted simulators and quits Simulator.app;
- prints `df -h`.

It keeps the shared module cache (`~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex`), simulator runtimes and devices, and all source and user data. Pass `--keep` to skip cleanup while debugging; `scripts/build.sh clean` removes it later.

`scripts/build_country_boundaries.py` only writes the output file you name, so it has nothing to clean.
