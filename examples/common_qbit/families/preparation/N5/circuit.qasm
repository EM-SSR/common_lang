OPENQASM 3.0;
include "stdgates.inc";
gate counter_probe(_gate_p_0) _gate_q_0 {
}
gate counter_probe_0(_gate_p_0) _gate_q_0 {
}
gate counter_probe_1(_gate_p_0) _gate_q_0 {
}
gate counter_probe_2(_gate_p_0) _gate_q_0 {
}
qubit[1] q;
x q[0];
x q[0];
x q[0];
x q[0];
x q[0];
counter_probe(0) q[0];
counter_probe_0(1.0) q[0];
counter_probe_1(2.0) q[0];
counter_probe_2(3.0) q[0];
