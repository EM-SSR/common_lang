"""ツイ数関数計算機の共有サービス。"""

from .session import CalculatorSession

_SESSION = None


def get_session():
    """GUI と MCP が参照する一つの計算セッションを返す。"""
    global _SESSION
    if _SESSION is None:
        _SESSION = CalculatorSession()
    return _SESSION

