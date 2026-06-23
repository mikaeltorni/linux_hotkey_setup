#!/usr/bin/env python3
"""Centralized logging for Python hotkey helper services.

Service scripts import ``LOGGER``, ``get_logger``, and ``log_call`` from this
module. Logging is best-effort, idempotent, and routed to stderr so systemd
user services are captured by journald without a private log file.
"""

from __future__ import annotations

import functools
import inspect
import logging
from pathlib import Path
from typing import Any, Callable, TypeVar

LOG_FORMAT = "%(asctime)s %(levelname)s [%(name)s] %(message)s"
F = TypeVar("F", bound=Callable[..., Any])


def get_logger(name: str = "ctrl-back-window-tiler") -> logging.Logger:
    """Return the idempotent service logger writing to stderr.

    Args:
        name: Logger name shown in every record.

    Returns:
        A configured logger. If logging setup fails, the logger falls back to a
        null handler so callers never crash on diagnostics.
    """
    logger = logging.getLogger(name)
    logger.setLevel(logging.DEBUG)
    logger.propagate = False
    if logger.handlers:
        return logger
    try:
        handler: logging.Handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter(LOG_FORMAT))
    except OSError:
        handler = logging.NullHandler()
    logger.addHandler(handler)
    return logger


def log_call(logger: logging.Logger, level: int = logging.DEBUG) -> Callable[[F], F]:
    """Trace a function by logging bound arguments on entry and return on exit.

    Each record includes the wrapped function's ``file:qualname``. The decorator
    intentionally logs no timing or intermediate state.

    Args:
        logger: Centralized logger obtained from ``get_logger``.
        level: Logging level for the enter and exit records.

    Returns:
        A decorator that wraps the target callable.
    """

    def decorator(func: F) -> F:
        location = f"{Path(func.__code__.co_filename).name}:{func.__qualname__}"
        signature = inspect.signature(func)

        @functools.wraps(func)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            bound = signature.bind(*args, **kwargs)
            bound.apply_defaults()
            rendered = ", ".join(
                f"{name}={value!r}" for name, value in bound.arguments.items()
            )
            logger.log(level, "ENTER %s(%s)", location, rendered)
            result = func(*args, **kwargs)
            logger.log(level, "EXIT %s -> %r", location, result)
            return result

        return wrapper  # type: ignore[return-value]

    return decorator


LOGGER = get_logger()
