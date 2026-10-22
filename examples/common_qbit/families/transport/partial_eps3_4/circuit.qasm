OPENQASM 3.0;
include "stdgates.inc";
gate counter_transport(_gate_p_0, _gate_p_1) _gate_q_0 {
}
bit[1] c;
qubit[1] q;
h q[0];
counter_transport(1.0, 0.75) q[0];
c[0] = measure q[0];
