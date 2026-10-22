; 小さい方を返す。分岐と phi（pc_prev の読み）の見本
define i8 @min(i8 %a, i8 %b) {
e:
  %c = icmp ult i8 %a, %b
  br i1 %c, label %t, label %f
t:
  br label %m
f:
  br label %m
m:
  %y = phi i8 [ %a, %t ], [ %b, %f ]
  ret i8 %y
}
