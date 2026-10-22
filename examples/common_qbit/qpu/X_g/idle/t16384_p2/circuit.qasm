OPENQASM 3.0;
include "stdgates.inc";
bit[1] c;
qubit[1] q;
h q[0];
delay[16384dt] q[0];
rz(pi) q[0];
h q[0];
c[0] = measure q[0];
