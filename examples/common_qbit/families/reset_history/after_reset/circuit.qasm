OPENQASM 3.0;
include "stdgates.inc";
bit[2] c;
qubit[1] q;
h q[0];
c[0] = measure q[0];
reset q[0];
c[1] = measure q[0];
