"""Entry point — `python3 -m fetch_asset`. Dispatches to CLI or GUI."""

import sys

from .cli import main


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
