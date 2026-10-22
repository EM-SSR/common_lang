# referenceとは呼べない程度の備忘録

Common言語にしろコモン公用語にしろ、根底にあるのは数学で、5みたいな小さい自然数を定義するのにすら

"""
hu hu hu hu hu ka, no ka, no ka, no ka, no ka.

hu ka, he ka, no ka, he ka, no ka, hu ka, no ka. 

hu ka, hu ka, no ka, he ka, no ka. hu ka, no ka.

hu ka, he ka, no ka, he ka, no ka, ki hu ka, no ka.
"""

など、複数の解法がある。

これだけだとこの語彙が何を言っているか？は分かりにくいが、下に説明すると:

hu : 最初に書く「1」。
    この1を操作する。基本的にこれがないとプログラムは始まらない。

he : コピー。
    与えられた語の値の順番の語をコピーしてw[0]に値を置く。

ka : 句読点。
    操作を区切る。これがあって操作を区切ることができる(逆に言えば、無ければ区切られない)。

no : 加算。
    加算の操作。二つの対象があって初めて適用可能(当然ながら)。

ha : 負にする・裏返す。
    実はコモン公用語において引き算は存在しない。引き算をしたいなら、引く数を裏返す必要がある。hukahakaなら-1を作るだけ。

mu : 書き込み・左の語番号に右の値を書き込む。
    上に今まで挙がった中で唯一の左右による作用の違いを持つ単語。左の値で定義された語を右の値の語に書き込む。つまり、 **右の値が語の番号。左の単語は語の中身** になる。普通のプログラミングっぽく言えば、右がメモリアドレス。左が値。まぁそんな単純な話ではもちろんないんだけど...。
    それと、できるだけ1とかあまりにも小さい語を指定すべきではない。プログラムにも寄るけど、基本的に小さい語は新しい語の定義に一時的に使う。大きい語を一時メモリに使おう。

me : 成功報告・C言語のreturn 0みたいなやつ。
    frontierが空っぽのまま実行終了したいときに必要な単語。

mi : 非破壊読み出し・語番号を作る。
    Common言語で状態を読み出す唯一の方法。入力は語番号で、中身の語を返す。非破壊読み出し。

hi : 比較器
    左の語の値が右の語の値より小さければ1、左の語の値が右の語の値より大きければ0。

mo : 忘れる・語の値を捨てる
    frontierをw[0]に戻す。

区切りがなければ操作は適用されるため、こういうトリッキーなこともできる:

    すべての hu ka 。つまり1をまとめるためにnoを多重につける。 
    hu ka, hu ka, hu ka, hu ka, hu ka, hu ka, hu ka, no no no ka, no no ka, no ka.
    = 7

    最後のno kaをなくしてみる。
    hu ka, hu ka, hu ka, hu ka, hu ka, hu ka, hu ka,no no no ka, no no ka.
    = 4, 3

    no no ka も消す。
    hu ka, hu ka, hu ka, hu ka, hu ka, hu ka, hu ka,no no no ka.
    =  2, 2, 2, 1

    1が残っていてきしょいので、7個のhu ka 定義のうち最後のhu kaを一つ消して6個にする。
    hu ka, hu ka, hu ka, hu ka, hu ka, hu ka,no no no ka. 

    8を作ってから1 = hu kaを裏返して引いてみる。ついでにhu ka を8つ定義するためのkaを省略する。

    hu hu hu hu hu hu hu hu ka, no no no no ka, no no ka, no ka.

    hu ka, ha ka. no ka.

    同じことを、8を作るうえで8つバカ正直に1を定義するのは愚かなので、文明人らしく2進数風に書いてみる。

    hu ka, he ka, no ka, he ka, no ka, he ka, no ka.

    hu ka, ha ka. no ka.

    天邪鬼なことに、-8をつくってから戻して計算する。

    hu ka, ha ka, he ka, no ka, he ka, no ka, he ka, no ka.

    hu ka. no ka, ha ka.

brainfuck言語みがあるのは確かにそう...。

