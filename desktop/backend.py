"""Run Sonder's existing backend for the desktop window."""

import os
import socket
import sys
from threading import Thread

import uvicorn


class DesktopServer(uvicorn.Server):
    async def startup(self, sockets=None):
        await super().startup(sockets=sockets)
        if self.started:
            print(f"SONDER_PORT={self.servers[0].sockets[0].getsockname()[1]}", flush=True)


def stop_when_window_closes(server):
    if sys.stdin is not None:
        sys.stdin.buffer.read(1)
        server.should_exit = True


def main():
    with socket.socket() as legacy_server:
        legacy_server.settimeout(0.3)
        if legacy_server.connect_ex(("127.0.0.1", 8765)) == 0:
            print("Close the previous Sonder server window before starting the desktop app.", file=sys.stderr)
            return 1

    os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
    # Load native FFT and audio libraries before the separation worker starts.
    from scipy import fft
    import soundfile

    server = DesktopServer(uvicorn.Config(
        "app:app",
        host="127.0.0.1",
        port=0,
        use_colors=False,
        timeout_graceful_shutdown=2,
    ))
    Thread(target=stop_when_window_closes, args=(server,), daemon=True).start()
    server.run()
    return 0 if server.started else 1


if __name__ == "__main__":
    raise SystemExit(main())
