OPENQASM 3.0;
include "stdgates.inc";
gate counter_transport(_gate_p_0, _gate_p_1) _gate_q_0 {
}
gate counter_transport_0(_gate_p_0, _gate_p_1) _gate_q_0 {
}
gate counter_transport_1(_gate_p_0, _gate_p_1) _gate_q_0 {
}
gate counter_transport_2(_gate_p_0, _gate_p_1) _gate_q_0 {
}
bit[8] c;
qubit[8] q;
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];
counter_transport(0, 1.0) q[0];
counter_transport(0, 1.0) q[1];
counter_transport_0(1.0, 1.0) q[2];
counter_transport(0, 1.0) q[3];
counter_transport(0, 1.0) q[4];
counter_transport_1(1.0, 1.0) q[5];
counter_transport(0, 1.0) q[6];
counter_transport_2(1.0, 1.0) q[7];
c[0] = measure q[0];
c[1] = measure q[1];
c[2] = measure q[2];
c[3] = measure q[3];
c[4] = measure q[4];
c[5] = measure q[5];
c[6] = measure q[6];
c[7] = measure q[7];
