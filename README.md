# AppManager

A macOS menu bar utility for viewing running apps and their resident memory, switching to an app, and quitting or restarting selected apps.

Requires macOS 14 or later and Swift 6 command-line tools.

```sh
git clone https://github.com/quittnet/AppManager.git
cd AppManager
bash ./check_app_manager.sh
bash ./launch_app_manager.sh
```

The launcher builds and installs AppManager in `~/Applications`. Click its menu bar icon to open the app list. Use Command-click or Shift-click to select multiple apps, then choose an action from the **Actions** menu.

Choose **Actions > Quit All Except Selected** to keep the selected apps open and request a normal quit for every other listed app. Apps with unsaved work can show save prompts. The action requires at least one selection and keeps AppManager running.

Use **More options (…) > Launch at Login** to toggle automatic startup. If macOS requires approval, choose **Allow in Login Items…** from the same menu.
