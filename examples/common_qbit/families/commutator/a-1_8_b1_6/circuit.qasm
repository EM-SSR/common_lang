OPENQASM 3.0;
include "stdgates.inc";
qubit[2] q;
s q[0];
x q[1];
sdg q[0];
z q[1];
