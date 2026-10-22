; %n0 を 0 まで数え下げ、回数を返す。単調停止フラグと omega 読みの見本
define i4 @count(i4 %n0) {
e:
  br label %l
l:
  %n = phi i4 [ %n0, %e ], [ %n1, %s ]
  %k = phi i4 [ 0, %e ], [ %k1, %s ]
  %z = icmp eq i4 %n, 0
  br i1 %z, label %x, label %s
s:
  %n1 = sub nsw i4 %n, 1
  %k1 = add nsw i4 %k, 1
  br label %l
x:
  ret i4 %k
}
