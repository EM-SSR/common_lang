"""ツイ数関数計算機の起動点。"""

import argparse
import threading

from calculator import get_session
from calculator.gui import run as run_gui
from calculator.mcp_server import run as run_mcp


def main():
    parser = argparse.ArgumentParser(description="ツイ数関数計算機を起動します。")
    parser.add_argument("--mcp", action="store_true", help="MCP サーバーだけを起動します。")
    parser.add_argument("--both", action="store_true", help="GUI と MCP を同じプロセスで起動します。")
    args = parser.parse_args()
    session = get_session()
    if args.mcp:
        run_mcp(session)
        return
    if args.both:
        threading.Thread(target=run_mcp, args=(session,), daemon=True,
                         name="MCP-stdio").start()
    run_gui(session)


if __name__ == "__main__":
    main()

