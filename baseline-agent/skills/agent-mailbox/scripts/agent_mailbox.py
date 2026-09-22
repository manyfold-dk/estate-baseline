#!/usr/bin/env python3
"""Entry point for the agent-mailbox skill.

Adds this script's directory to sys.path so the ``ambx`` package imports
regardless of where the launcher invokes it from, then dispatches to the CLI.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ambx.cli import main  # noqa: E402

if __name__ == "__main__":
    main()
