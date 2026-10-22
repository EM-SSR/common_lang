; メモリ窓へ二語書き、読み直して足す。load / store のマルチプレクサの見本
define i8 @memsum(i8 %a, i8 %b) {
e:
  store i8 %a, ptr 0
  store i8 %b, ptr 1
  %x = load i8, ptr 0
  %y = load i8, ptr 1
  %s = add i8 %x, %y
  ret i8 %s
}
