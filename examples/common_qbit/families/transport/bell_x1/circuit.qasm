OPENQASM 3.0;
include "stdgates.inc";
gate counter_transport(_gate_p_0, _gate_p_1) _gate_q_0 {
}
bit[1] c;
qubit[2] q;
h q[0];
cx q[0], q[1];
counter_transport(1.0, 1.0) q[0];
c[0] = measure q[1];
