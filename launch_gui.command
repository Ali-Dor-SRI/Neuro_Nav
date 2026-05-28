#!/usr/bin/env bash
# launch_gui.command -- Mac entry point. Double-click in Finder to launch.
#
# Runs python3 -m brainsight_gui from inside python/, which is where the
# brainsight_gui package lives.

# Move to the directory this script is in (the repo root).
cd "$(dirname "$0")" || exit 1
cd python || { echo "python/ directory not found"; exit 1; }

# Resolve a Python 3 interpreter
if command -v python3 >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1; then
    PY=python
else
    echo "No python interpreter found on PATH."
    echo "Install Python 3 from https://www.python.org/downloads/macos/"
    read -n1 -r -p "Press any key to close..." _
    exit 1
fi

# Run the GUI. Keep the Terminal window open afterwards so the operator
# can read any traceback.
"$PY" -m brainsight_gui
EXIT=$?

if [ $EXIT -ne 0 ]; then
    echo ""
    echo "GUI exited with code $EXIT"
    read -n1 -r -p "Press any key to close..." _
fi
