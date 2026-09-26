"""AUM's identity and terminal-only banner policy."""

PRODUCT = "AUM - Azure Usage Management"
COMPACT = "AUM · Azure Usage Management"
BANNER = " _____ _____ _____ \n|  _  |  |  |     |\n|     |  |  | | | |\n|__|__|_____|_|_|_|"


def show_banner(*, tty, as_json=False, plain=False, screen_reader=False):
    return tty and not (as_json or plain or screen_reader)
