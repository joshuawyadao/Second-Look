"""Small signal boundary for the three connected smoke command-line programs."""

from contextlib import contextmanager
import signal


class Cancelled(Exception):
    def __init__(self, signum: int):
        self.signum = signum


@contextmanager
def cancellation_guard():
    """Unwind on the first interrupt; defer later interrupts until cleanup ends."""
    previous = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
    cancelled = False

    def interrupt(signum, _frame):
        nonlocal cancelled
        if not cancelled:
            cancelled = True
            raise Cancelled(signum)

    try:
        for number in previous:
            signal.signal(number, interrupt)
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
