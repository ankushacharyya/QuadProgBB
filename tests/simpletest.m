n = 5;
H = 2*rand(n) - 1;
H = 0.5*(H+H');
f = 2*rand(n,1) - 1;
A = [];
b = [];
Aeq = [];
beq = [];
LB = zeros(n,1);
UB = ones(n,1);

quadprogbb(H,f,A,b,Aeq,beq,LB,UB)
