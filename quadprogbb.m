function [fval,x,time,stat] = quadprogbb(H,f,A,b,Aeq,beq,LB,UB,max_time,cons)
%addpath(genpath('cplex122/matlab/'));

use_quadprog = 1;

%% statistics: 
%% tPre: time spent on preprocessing
%% tLP:  time spent on calculating bounds in preprocessing
%% tBB:  time spent on B&B
%% nodes: total nodes_solved

stat = struct('tPre',0,'tLP',0,'tBB',0,'nodes',0);

tic;

% warning('Could I be introducing unexpected error with all the transformations? Right now, all B&B calculations are based on transformed problem.');
% warning('Can complmentarity help strengthen LPs to get dual variable bounds? Dont think so because quadratic terms including dual vars are not present yet.');
% warning('Final x and fval returned are for transformed problem!');
% warning('Probably should handle leaf nodes more confidently.');

%% ----------------
%% Set user options
%% ----------------

my_tol  = 1.0e-6;     % Fathoming and branching tolerance
tol = 1e-8;           % if |ub-lb| < tol, we consider lb==ub
max_iter = 1000;      % Max iters allowed for solving each relaxation

%%-------------------------------------------
%% Set max_time if user has *not* specified it
%% -------------------------------------------

if nargin < 9
    max_time = Inf;
end

%% -------------------------------------------
%% Set constant term if user has *not* specified it
%% -------------------------------------------

if nargin < 10
    cons = 0;
end

%% -------------------------------
%% Ensure Matlab uses only one CPU
%% -------------------------------

maxNumCompThreads(1);

%% ------------------------------
%% Check inputs for simple errors
%% ------------------------------

checkinput(H,f,A,b,Aeq,beq,LB,UB);

%% ------------------------------
%% Problem is now turned into standard form
%%
%%   min   0.5*x'*H*x + f'*x
%%   s.t.  A*x = b, x >= 0
%%         [x*x']_E == 0
%% Bounds x <= 1 are valid
%% ------------------------------

[H,f,A,b,E,cons,L,U,sstruct,timeLP] = standardform(H,f,A,b,Aeq,beq,LB,UB,cons);

fprintf('\n');
fprintf('Pre-Processing is complete, time = %d\n\n',toc);

stat.tPre = toc;
stat.tLP = timeLP;

if sstruct.flag
  fval = sstruct.obj;
  x = getsol([],sstruct);
  time = toc;
  nodes_solved = 0;
  fprintf('\n');
  fprintf('FINAL STATUS 1: optimal value = %.8e\n', fval);
  fprintf('FINAL STATUS 2: (created,solved,pruned,infeas,left) = (%d,%d,%d,%d,%d)\n', ...
      0,0,0,0,0);
  fprintf('FINAL STATUS 3: solved = fully + fathomed + poorly : %d = %d + %d + %d\n', ...
      0,0,0,0);
  fprintf('FINAL STATUS 4: time = %d\n', time);
  return
end
 
cmp1 = sstruct.cmp1;
cmp2 = sstruct.cmp2;
lenB = sstruct.lenB;
lenL = sstruct.lenL;
m = sstruct.m;
n = sstruct.n;

m0 = length(cmp1);

Fx = find(abs(L(cmp1)-U(cmp1))<tol & abs(L(cmp1)-0)<tol);
Fz = find(abs(L(cmp2)-U(cmp2))<tol & abs(L(cmp2)-0)<tol);

%% Setup constants for passage into opt_dnn subroutine

%% Constant n saved above

bign = size(A,2);

%% Assign fixed values to lower and upper bounds

L_save = L; % Subproblems will only differ in L and U
U_save = U;

B = [];

%% -------------------------
%% Initialize B&B structures
%% -------------------------

LBLB = -Inf;
FxFx{1} = Fx;
FzFz{1} = Fz;
SS = zeros((1+bign)^2,1);
SIGSIG = -1; % Signal that we want default sig in aug Lag algorithm

%% ------------------------------------------------------------------
%% Calculate first global upper bound and associated fathoming target
%% ------------------------------------------------------------------

if use_quadprog
  [xx,gUB] = quadprog(H,f,[],[],A,b,L_save,U_save);
else
  xx = [];
  gUB = Inf;
end

if gUB == Inf
  LB_target = Inf;
else
  LB_target = gUB - my_tol*max(1,abs(gUB));
end
LB_beat = -Inf;

%% ----------------------
%% ----------------------
%% Begin BRANCH-AND-BOUND
%% ----------------------
%% ----------------------

nodes_created         = 1;
nodes_solved          = 0;
nodes_solved_fully    = 0;
nodes_solved_fathomed = 0;
nodes_solved_poorly   = 0;
nodes_infeasible      = 0;
nodes_pruned          = 0;

%% ------------------------------------------
%% While there are still nodes in the tree...
%% ------------------------------------------

%% Store fixed components index to prevent these variables's bounds from
%% changing
Fx0 = Fx;
Fz0 = Fz;

t0 = m+lenL;
t1 = m+lenL+lenB;


while length(LBLB) > 0

    %% ------------
    %% Print status
    %% ------------

    fprintf('\n');
    fprintf('STATUS 1: (gUB,gLB,gap) = (%.8e, %.8e, %.3f%%)\n', ...
        gUB+cons, min(LBLB)+cons, 100*(gUB - min(LBLB))/max([1,abs(gUB+cons)]));
    fprintf('STATUS 2: (created,solved,pruned,infeas,left) = (%d,%d,%d,%d,%d)\n', ...
        nodes_created, nodes_solved, nodes_pruned, nodes_infeasible, length(LBLB));
    fprintf('STATUS 3: solved = fully + fathomed + poorly : %d = %d + %d + %d\n', ...
        nodes_solved, nodes_solved_fully, nodes_solved_fathomed, nodes_solved_poorly);
    fprintf('STATUS 4: time = %d\n', toc);

    %% -------------------------------------
    %% Terminate if too much time has passed
    %% -------------------------------------

    if toc > max_time
        break;
    end

    %% -----------------------------------------------
    %% Sort nodes for 'best-bound' node-selection rule
    %% -----------------------------------------------

    [LBLB,I] = sort(LBLB,2,'descend');
    FxFx = FxFx(I);
    FzFz = FzFz(I);
    SS = SS(:,I);
    SIGSIG = SIGSIG(I);

    %% ---------------------------------------------------
    %% Pull last problem off the problem list (best-bound)
    %% ---------------------------------------------------

    LB = LBLB(end);
    
    Fx = FxFx(end); Fx = Fx{1};
    Fz = FzFz(end); Fz = Fz{1};
    S = reshape(SS(:,end), 1+bign, 1+bign);
    SIG = SIGSIG(end);
    if SIG < 0.0 % Signal that we want default sig in aug Lag algorithm
        SIG = [];
    end

    %% ---------------------------------
    %% Delete that problem from the tree
    %% ---------------------------------

    LBLB = LBLB(1:end-1);
    FxFx = FxFx(1:end-1);
    FzFz = FzFz(1:end-1);
    SS = SS(:,1:end-1);
    SIGSIG = SIGSIG(1:end-1);

    %% ------------------
    %% Handle single node
    %% ------------------

    %% ----------------------------
    %% Prepare problem to be solved
    %% ----------------------------

    L = L_save;
    U = U_save;

    %%------------------------------------------
    %% Prepare L and U for new structure of vars
    %%------------------------------------------
    %% X(Fx) = 0, X(Fz) = 0

    set1 = cmp1(Fx);
    set2 = cmp2(Fz);
    U(set1) = 0;     % set the components to be zero
    U(set2) = 0;     % set the lambda components to be zero
    
    %% Setup LB_beat

    if LB == -Inf
      LB_beat = -Inf;
    else
      LB_beat = LB - my_tol*max(1,abs(LB));
    end

    %% Sam: Need to use U-L to find fixed variables. Add same
    %% fixings to Ax=b. If variable is fixed to 0, can zero
    %% out other entries in same column of A.


    [local_A,local_b] = fixedAb(A,b,L,U);

    %% -----------------------------------
    %% Solve doubly nonnegative relaxation
    %% -----------------------------------

    fprintf('\n=======================================================================\n');
    fprintf('------------------ Commencing solution of node %4d -------------------\n', nodes_solved+1);

    Fx
    Fz

    if isfeasible(local_A,local_b,L,U)

      [newLB,Y,Z,S,SIG,ret] = opt_dnn(H,f,local_A,local_b,B,E,L,U,max_iter,S,SIG,LB_target,LB_beat,max_time-toc,cons);

    else

      ret = 'infeas';

    end

    fprintf('\n------------------------------- done! ---------------------------------\n');
    fprintf('=======================================================================\n\n');

    if ~strcmp(ret,'infeas')

      %% ------------
      %% Post-process
      %% ------------

      %% If newLB < LB, then it means that the subproblem did not solve
      %% well because theoretically, newLB >= LB at optimality. So we take
      %% this as a sign that sig needs to be reset. So we set SIG = -1 to
      %% signal that we want sig reset for the children.
      %%
      %% Otherwise, we update LB and save SIG for any children.

      if strcmp(ret,'poor')
        SIG = -1.0;
        S = zeros(size(S,1));
      end
      if newLB >= LB
        LB = newLB;
      end

      nodes_solved = nodes_solved + 1;
      if strcmp(ret,'fathom')
        nodes_solved_fathomed = nodes_solved_fathomed + 1;
      elseif strcmp(ret,'poor')
        nodes_solved_poorly = nodes_solved_poorly + 1;
      else 
        nodes_solved_fully = nodes_solved_fully + 1;
      end

      %% Save multiplier

      S = reshape(S, (1+bign)^2, 1);

      %% Extract upper bound (4-part primal heuristic)
      %%
      %% First extract 0-th column of Y and project it onto Ax=b,x>=0
      %% using CPLEX. Get value and update gUB if necessary.
      %% 
      %% Then run quadprog() from this point (if desired).
      %%
      %% Next extract 0-th column of Z and project it onto Ax=b,x>=0 using
      %% CPLEX. Get value and update gUB if necessary.
      %% 
      %% Then run quadprog() from this point (if desired).
      %%
      %% We presume that CPLEX can return as good a feasible solution as
      %% any algorithm. (We do not check anything at the moment. Is this
      %% safe?)
      %%
      %% Right now, we use projected version of 0-th col of Z for
      %% branching. Is this a good choice?

      x0 = Y(2:bign+1,1);
      x0 = project(x0,local_A,local_b,L,U); %% In CPLEX we trust! 
      x0val = 0.5*x0'*H*x0 + f'*x0;
      if x0val < gUB % x0 is best so far
        gUB = x0val;
        xx = x0;
      end

      if use_quadprog
        [tmpx,tmpval] = quadprog(H,f,[],[],A,b,L_save,U_save,x0);
      else
        tmpx = [];
        tmpval = Inf;
      end
      if tmpval < gUB
        gUB = tmpval;
        xx = tmpx;
      end

      x0 = Z(2:bign+1,1)/Z(1,1);
      x0 = project(x0,local_A,local_b,L,U); %% In CPLEX we trust! 
      x0val = 0.5*x0'*H*x0 + f'*x0;
      if x0val < gUB % x0 is better than what quadprog found
        gUB = x0val;
        xx = x0;
      end

      if use_quadprog
        [tmpx,tmpval] = quadprog(H,f,[],[],A,b,L_save,U_save,x0);
      else
        tmpx = [];
        tmpval = Inf;
      end
      if tmpval < gUB
        gUB = tmpval;
        xx = tmpx;
      end

      %% Update fathoming target

      if gUB == Inf
        LB_target = Inf;
      else
        LB_target = gUB - my_tol*max(1,abs(gUB));
      end

      %% ----------------------
      %% Prune tree by gUB
      %% ----------------------

      tmpsz = length(LBLB);

      I = find(LBLB < LB_target);
      LBLB = LBLB(I);
      FxFx = FxFx(I);
      FzFz = FzFz(I);
      SS = SS(:,I);
      SIGSIG = SIGSIG(I);

      nodes_pruned = nodes_pruned + (tmpsz - length(LBLB));

      %% ------------------------------------------------------------------
      %% Select index to branch on (but will only branch if LB < LB_target)
      %% ------------------------------------------------------------------

      if length(union(Fx,Fz)) < m0
          x0 = Y(2:bign+1,1);
          s = x0(cmp1);
          lambda = x0(cmp2);
          [vio,index] = max( s .* lambda );
          if vio == 0 % Got unlucky, just select first index available for branching
              Ffix = union(Fx0, Fz0);
              tmpI = setdiff( setdiff(1:m0,Ffix) , union(Fx,Fz));
              index = tmpI(1);
          end

          %% ---------------------
          %% Branch (if necessary)
          %% ---------------------
          %%
          %% We do not check primal feasibility because (x,z) are assumed
          %% part of a feasible x0 via CPLEX (see above). In CPLEX we
          %% trust!
          %%
           if LB < LB_target & vio > my_tol

              if index <= t0
                Fxa = union(Fx,index);
                Fza = Fz;

                Fxb = Fx;
                Fzb = union(Fz,index);

                LBLB   = [LBLB  ,LB ,LB ];
                SS     = [SS    ,S  ,S  ];
                SIGSIG = [SIGSIG,SIG,SIG];

                FxFx{length(FxFx)+1} = Fxa;
                FzFz{length(FzFz)+1} = Fza;

                FxFx{length(FxFx)+1} = Fxb;
                FzFz{length(FzFz)+1} = Fzb;

                nodes_created = nodes_created + 2;

              elseif index <= t1
              %% if t0 < index <= t1, then only add index to Fx if index+lenB not in Fx
              %% in case the second 'if' holds, then add index+lenB to Fz

              if ~ismember(index+lenB,Fx)
                Fxa = union(Fx,index);
                Fza = union(Fz,index+lenB);
                FxFx{length(FxFx)+1} = Fxa;
                FzFz{length(FzFz)+1} = Fza;
                LBLB   = [LBLB  ,LB ];
                SS     = [SS    ,S  ];
                SIGSIG = [SIGSIG,SIG];
                nodes_created = nodes_created + 1;
              end
              Fxb = Fx;
              Fzb = union(Fz,index);
              FxFx{length(FxFx)+1} = Fxb;
              FzFz{length(FzFz)+1} = Fzb;
              LBLB   = [LBLB  ,LB ];
              SS     = [SS    ,S  ];
              SIGSIG = [SIGSIG,SIG];
              nodes_created = nodes_created + 1;
            else
              %% if index > t1, then only add index to Fx if index-lenB not in Fx
              %% in case the second if holds, then add index-lenB to Fz

              if ~ismember(index-lenB,Fx)
                Fxa = union(Fx,index);
                Fza = union(Fz,index-lenB);
                FxFx{length(FxFx)+1} = Fxa;
                FzFz{length(FzFz)+1} = Fza;
                LBLB   = [LBLB  ,LB ];
                SS     = [SS    ,S  ];
                SIGSIG = [SIGSIG,SIG];
                nodes_created = nodes_created + 1;
              end
              Fxb = Fx;
              Fzb = union(Fz,index);
              FxFx{length(FxFx)+1} = Fxb;
              FzFz{length(FzFz)+1} = Fzb;
              LBLB   = [LBLB  ,LB ];
              SS     = [SS    ,S  ];
              SIGSIG = [SIGSIG,SIG];
              nodes_created = nodes_created + 1;
            end

              %% ----------------------
              %% End branching decision
              %% ----------------------

          end

      end

    else

      nodes_infeasible = nodes_infeasible + 1;

    end

    %% ---------------------------
    %% End handling of single node
    %% ---------------------------

    %% -------------------------------
    %% End loop over nodes in the tree
    %% -------------------------------

end

%% -----------------
%% Print final stats
%% -----------------

fprintf('\n');
fprintf('FINAL STATUS 1: optimal value = %.8e\n', gUB+cons);
fprintf('FINAL STATUS 2: (created,solved,pruned,infeas,left) = (%d,%d,%d,%d,%d)\n', ...
    nodes_created, nodes_solved, nodes_pruned, nodes_infeasible, length(LBLB));
fprintf('FINAL STATUS 3: solved = fully + fathomed + poorly : %d = %d + %d + %d\n', ...
    nodes_solved, nodes_solved_fully, nodes_solved_fathomed, nodes_solved_poorly);
fprintf('FINAL STATUS 4: time = %d\n', toc);

fval = gUB+cons;

%% ---------------------------------------------
%% Extract the solution to the original problem
%% ---------------------------------------------

x = getsol(xx,sstruct);

time = toc;
stat.tBB = time - stat.tPre;
stat.nodes = nodes_solved;

return


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function x = getsol(x,sstruct)
%% GETSOL reverse the transformation made, and return the solution to 
%%        the original problem.

if ~isempty(x)
  x = x(1:sstruct.n);
else
  x = sstruct.xx;
end

if ~sstruct.flag
  x = (sstruct.ub6-sstruct.lb6).*x + sstruct.lb6;
end

if ~isempty(sstruct.idxU5)
  x(sstruct.idxU5) = sstruct.ub5 .* x(sstruct.idxU5);
end

if ~isempty(sstruct.idxL5)
  x(sstruct.idxL5) = x(sstruct.idxL5) + sstruct.lb5;
end

if ~isempty(sstruct.idxU4)
  x(sstruct.idxU4) = sstruct.ub4 .* x(sstruct.idxU4);
end

if ~isempty(sstruct.idxL3)
  x(sstruct.idxL3) = x(sstruct.idxL3) + sstruct.lb3;
end

if ~isempty(sstruct.idxU2)
  x(sstruct.idxU2) = sstruct.ub2 - x(sstruct.idxU2);
end

if ~isempty(sstruct.fx1)
  len = length(sstruct.fx1)+length(x);
  y = zeros(len,1)
  y(sstruct.fx1) = sstruct.fxval1;
  y(setdiff(1:len,sstruct.fx1)) = x;
  x = y;
end

return


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


function [H,f,A,b,E,cons,L,U,sstruct,timeLP] = standardform(H,f,A,b,Aeq,beq,LB,UB,cons)

% If abs(difference of two values) < tol, the two values are considered
% to be equal

tol = 1e-8;
E = [];
sstruct = struct('flag',0,'obj',-inf,'fx1',[],'fxval1',[],'ub2',[],'idxU2',[],...
                'lb3',[],'idxL3',[],'ub4',[],'idxU4',[],'idxU5',[],'ub5',[],...
                'idxL5',[],'lb5',[],'lb6',[],'ub6',[]);
timeLP = 0;
%% -------------------------------------
%% Remove fixed variables
%% ------------------------------------- 
n = size(H,1);
FX  = find(abs(LB - UB)< tol);

if length(FX) > 0

  %% track change: 1
  sstruct.fx1 = FX;
  sstruct.fxval1 = LB(FX);
    
    %% FXc == complement of FX or the components of x that are not fixed
    
    FXc = setdiff(1:n,FX);
    
    %% Calculate the constants in objective after removing the fixed vars
    
    cons = cons + 0.5*LB(FX)'*H(FX,FX)*LB(FX) + f(FX)'*LB(FX);

    %% Update data after removing fixed components
    
    f   = f(FXc) + H(FXc,FX)*LB(FX);
    H   = H(FXc,FXc);
    b   = b   - A  (:,FX)*LB(FX); A   = A  (:,FXc);
    beq = beq - Aeq(:,FX)*LB(FX); Aeq = Aeq(:,FXc);

    %% Update the bounds for the non-fixed components of x
    
    LB = LB(FXc);
    UB = UB(FXc);

end

% remove linearly dependent equalities
% inequality does not matter

[tmp_m,tmp_n] = size(Aeq);
tmp_m1 = rank(Aeq);

if tmp_m1 < min(tmp_m,tmp_n)
  tmp = [Aeq beq]';
  [r, rowidx] = rref(tmp);
  Aeq = Aeq(rowidx,:);
  beq = beq(rowidx);
end

[H,f,A,b,Aeq,beq,LB,UB,cons,sstruct,tlp] = refm1(H,f,A,b,Aeq,beq,LB,UB,cons,sstruct);

timeLP = timeLP + tlp;
%% ----------------------------------------------
%% Now problem becomes:
%%
%%   min  .5*x*H*x + f*x + cons
%%   s.t.   A x <=  b              ( lamabda >=0 )
%%          Aeq x = beq            ( y free )
%%          0 <= xL                ( zL >=0 )
%%          0 <= xB <= 1           ( zB>=0, rB >=0)
%%
%% Now we are to formulate KKT system, and
%% calculate bounds on all vars.
%% -----------------------------------------------
n = size(H,1);
m = size(A,1);
meq = size(Aeq,1);
i1 = isfinite(LB);
i2 = isfinite(UB);

%% now the meaning of idxL and idxU has changed.
%% idxL = LB finite + UB infinite
%% idxU = both LB & UB finite

idxL = find(i1 & ~i2);
idxB = find(i1 & i2);
lenL = length(idxL);
lenB = length(idxB);

%% -----------------------------
%% Calculate bounds for all vars
%% -----------------------------
[L,U,tmp1,tmp2,tmp3,tmp4,tlp] = boundall(H,f,A,b,Aeq,beq,LB,UB,idxL,idxB);

timeLP = timeLP + tlp;

%% -------------------------------------------------
%% Prep equality constraints: A * xx = b 
%%
%%  (1)    H * x + A'*lambda + Aeq' * y - zL - zB + rB = -f
%%  (2)    A * x + s = b
%%  (3)    Aeq * x = beq
%%  (4)    xB + wB = 1
%% -------------------------------------------------

if norm(L-U)<tol
  sstruct.flag = 1;
  xLB = L(1:n);
  sstruct.xx = xLB;
  sstruct.obj = .5*xLB'*H*xLB + f'*xLB+cons;
  return
end

idxx = find(abs(U-L) <= tol);
L(idxx) = U(idxx);

nn = n+2*m+meq+lenL+3*lenB;

H1 = H; 
A1 = A; 
A2 = A;
Aeq1 = Aeq;
Aeq2 = Aeq;

xLB = L(1:n); xUB = U(1:n);
Dx = diag(xUB-xLB);

sLB = L(n+1:n+m); sUB = U(n+1:n+m);

n0 = n+m;
wLB = L(n0+1:n0+lenB); wUB = U(n0+1:n0+lenB);

n0 = n0+lenB;
lambdaLB = L(n0+1:n0+m); lambdaUB = U(n0+1:n0+m);

n0 = n0+m;
yLB = L(n0+1:n0+meq); yUB = U(n0+1:n0+meq);

n0 = n0+meq;
zLLB = L(n0+1:n0+lenL); zLUB = U(n0+1:n0+lenL);

n0 = n0+lenL;
zBLB = L(n0+1:n0+lenB); zBUB = U(n0+1:n0+lenB);

n0 = n0 + lenB;
rBLB = L(n0+1:end); rBUB = U(n0+1:end);

%% -----------------
%% Right-hand size b
%% -----------------

r1 = -f - H*xLB;
if ~isempty(tmp1)
  r1 = r1 - tmp1*zLLB;
end
if ~isempty(tmp2)
  r1 = r1 - tmp2*zBLB;
end
if ~isempty(tmp3)
  r1 = r1 - tmp3*rBLB;
end
if ~isempty(A1)
  r1 = r1 - A1'*lambdaLB;
end
if ~isempty(Aeq1)
  r1 = r1-Aeq1'*yLB;
end
if ~isempty(A)
  r2 = b - A*xLB - sLB;
else
  r2 = [];
end
if ~isempty(Aeq2)
  r3 = beq - Aeq2*xLB;
else
  r3 = [];
end
r4 = ones(lenB,1)- xLB(idxB)- wLB;

b = [r1;r2;r3;r4];

%% -----------------
%% Left-hand side A
%% -----------------

tmp1 = tmp1*diag(zLUB - zLLB);
tmp2 = tmp2*diag(zBUB - zBLB);
tmp3 = tmp3*diag(rBUB - rBLB);
row1 = [H*Dx zeros(n,m+lenB)];
if ~isempty(A1)
  row1 = [row1 A1'*diag(lambdaUB-lambdaLB)];
end
if ~isempty(Aeq1)
  row1 = [row1 Aeq1'*diag(yUB-yLB)];
end
if ~isempty(A2)
  row2 = A2*Dx;
else
  row2 = [];
end
if ~isempty(Aeq2)
  row3 = Aeq2*Dx;
else
  row3 = [];
end
if ~isempty(tmp4)
  row4 = tmp4*Dx;
else
  row4 = [];
end
%A = [ H*Dx zeros(n,m+lenB) A1'*diag(lambdaUB-lambdaLB) Aeq1'*diag(yUB-yLB) tmp1 tmp2 tmp3;
A = [ row1 tmp1 tmp2 tmp3;
      row2 diag(sUB-sLB) zeros(m,nn-n-m);
      row3 zeros(meq,nn-n);
      row4 zeros(lenB,m) diag(wUB-wLB) zeros(lenB, nn-n-m-lenB)];

%% ------------------------------
%% Shift and scale x affects objs
%% ------------------------------

cons = cons + 0.5*xLB'*H*xLB + f'*xLB;
f = f + H*xLB;

H = diag(xUB - xLB)*H*diag(xUB - xLB);
f = (xUB-xLB).* f;
n0 = nn-n;
f = [f ; zeros(n0,1)];
H = [H zeros(n,n0); 
     zeros(n0,n) zeros(n0)];

     
%% track change: 6
sstruct.lb6 = xLB;
sstruct.ub6 = xUB;


L = zeros(nn,1);
U = ones(nn,1);

%% ------------------------------
%% Prep complementarity
%% ------------------------------

E = zeros(nn);

%% s .* lambda = 0
n0 = n+m+lenB;
for i = 1:m
    E(n+i, n0+i ) = 1;
end

%% xL .* zL = 0
n0 = n0+m+meq;
for k=1:lenL
  i = idxL(k);
  E(i,n0+k) = 1;
end

%% xB .* zB = 0
n0 = nn - 2*lenB;
for k=1:lenB
  i = idxB(k);
  E(i,n0+k) = 1;
end

%% wB .* rB = 0

n00 = n+m; n0 = nn-lenB;
for k = 1:lenB
  E(n00+k,n0+k) = 1;
end

%% zB .* rB = 0
n00 = nn - 2*lenB;
for k = 1:lenB
  E(n00+k,n0+k) = 1;
end

E = E + E';

sstruct.cmp1 = [ n+(1:m)'; idxL ; idxB; n+m+(1:lenB)'];
sstruct.cmp2 = [ n+m+lenB+(1:m)'; nn-2*lenB-lenL+(1:lenL)'; nn-2*lenB+(1:lenB)'; nn-lenB+(1:lenB)'];
sstruct.lenB = lenB;
sstruct.m = m;
sstruct.n = n;
sstruct.lenL = lenL;

return

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


function [L,U,tmp1,tmp2,tmp3,tmp4,timeLP] = boundall(H,f,A,b,Aeq,beq,LB,UB,idxL,idxB)

%% BOUNDALL calculates the bounds for all the variables

%% -------------------------------------------------
%% Calculate bounds for all vars: ( x, s, lambda, y, wB, zB, zL, rB )
%% Solve the LP with variable X introduced to bound the dual vars
%%
%%      H(:)'*X(:) + f'*x + b'*lambda + beq'* y + rB= 0
%%      X_{i,j} <= x_j, X_{i,j} <= x_i
%%      X_{i,j} >= x_i + x_j - 1
%%
%% Suppose [m,n] = size(A). Dimension of variables: 
%%  - x: n
%%  - lambda, s: m
%%  - y: meq
%%  - rB,zB,wB: lenB
%%  - zL: lenL
%%  - X: .5*n*(n+1)
%%
%% Order of vars: ( x, X, s, wB, lambda, y, zL, zB, rB )
%% -------------------------------------------------

timeLP = 0;

Aeq0 = Aeq; 
beq0 = beq;
n = size(H,1);
m = size(A,1);
meq = size(Aeq,1);
lenL = length(idxL);
lenB = length(idxB);

nn = n+.5*n*(n+1)+2*m+meq+lenL+3*lenB;

%% BEGIN: prepare the data required by CPLEXINT

dH = diag(H);
H1 = 2*tril(H,-1);
H1 = H1 + diag(dH);
HH = [];
for j = 1:n
    HH = [HH; H1(j:end,j)];
end

%% Order of vars: ( x, X, s, wB, lambda, y, zL, zB, rB )

tmp1 = zeros(n,lenL);
for i = 1:lenL
  k = idxL(i);
  tmp1(k,i) = -1;
end
tmp2 = zeros(n,lenB);
for i=1:lenB
  k = idxB(i);
  tmp2(k,i) = -1;
end
tmp3 = -tmp2;
tmp4 = zeros(lenB,n);
for i=1:lenB
  k = idxB(i);
  tmp4(i,k) = 1;
end

%% -------------------------------------------------
%% The KKT system now is:
%%
%%  (1)    Aeq * x = beq
%%  (2)    A * x + s = b
%%  (3)    H * x + f + A'*lambda + Aeq' * y - zL - zB + rB = 0
%%  (4)    H \dot X + f' * x + b'*lambda + beq'*y + e' * rB = 0
%%  (5)    xB + wB = 1
%% -------------------------------------------------

if ~isempty(Aeq)
  Aeq = [ Aeq zeros(meq,nn-n)];  % (1) 
end

Aeq = [ Aeq ; 
        A    zeros(m,.5*n*(n+1)) eye(m) zeros(m,nn-n-m-.5*n*(n+1)) ;              % (2) 
        H    zeros(n,.5*n*(n+1)+m+lenB) A' Aeq0' tmp1 tmp2 tmp3 ;                 % (3)
        f'  HH'  zeros(1,m+lenB) b' beq0' zeros(1,lenL+lenB) ones(1,lenB) ;       % (4)
        tmp4 zeros(lenB,.5*n*(n+1)+m) eye(lenB) zeros(lenB,m+meq+lenL+2*lenB)  ]; % (5)


beq = [beq; b; -f; 0; ones(lenB,1)];
INDEQ = (1:length(beq))';

%% ---------------------------------------------------------------
%% Start to prepare the part of data modeling implied bounds on X,
%% including three parts.
%% ---------------------------------------------------------------

%% Part I & II: X_{i,j} <= x_j, X_{i,j} <= x_i

len = n + .5*n*(n+1);
qq = ones(n);
qq = tril(qq);
[I,J] = find(qq);
lenI = length(I);

block = zeros(1000,3);
range = 1000;
k = 1; rowid = 1;

for i=1:lenI
  ii = I(i);
  jj = J(i);
  block(k,:) = [rowid ii -1];  k = k + 1;
  if (k+5) > range
    block = [block; zeros(1000,3)];
    range = range + 1000;
  end
  block(k,:) = [rowid n+i 1];  k = k+1;
  rowid = rowid+1;
  if ii ~= jj
    block(k,:) = [rowid n+i 1];    k = k+1;
    block(k,:) = [rowid jj -1];    k = k+1;
    rowid = rowid+1;
  end
end

%% Part III:  X_{i,j} >= x_i + x_j - 1

for i=1:lenI
  ii = I(i);
  jj = J(i);
  block(k,:) = [rowid ii 1];
  k = k+1;
  if (k+5) > range
    block = [block; zeros(1000,3)];
    range = range + 1000;
  end
  if jj ~= ii
    block(k,:) = [rowid jj 1];
    k = k + 1;
  else
    block(k-1,3) = 2;
  end
  block(k,:) = [rowid n+i -1];
  k = k+1;
  rowid = rowid+1;
end
block = block(1:k-1,:);
AA = sparse(block(:,1),block(:,2),block(:,3),n^2+lenI,nn);
bb = [zeros(n^2,1); ones(lenI,1)];

%% Order of vars: ( x, X, s, wB, lambda, y, zL, zB, rB )
%% s >=0, lambda >=0, y free, wB>=0, xL>=0, 0<=xB
%% zL>=0, zB>=0,rB>=0
%% s .* lambda = 0, xL.*zL=0, xB.*zB=0, wB.*rB=0, zB.*rB = 0

LB = zeros(nn,1);
tmp = len+2*m+lenB;
LB(tmp+1:tmp+meq) = -inf;
UB = inf*ones(nn,1);

%% In previous transformation, x is bounded above by 1, and so 
%% does X. although we pretend that they are not there when 
%% doing complementarity 

UB(1:len) = 1;
UB(len+m+1:len+m+lenB) = 1;

%% END: prepare the data required by CPLEXINT

%% Recalculate bounds for x after adding KKT

L =  zeros(nn,1);
U =  ones(nn,1);
AA = [Aeq; AA];
bb = [beq; bb];

total = n + nn - len;

% calculate bounds for x

index0 = 1:n;
[xL,xU,tlp] = cplex_bnd_solve(AA, bb, INDEQ, LB, UB, index0);
L(index0) = xL;
U(index0) = xU;
timeLP = timeLP + tlp;

% Recalcualte bounds for the rest vars except X

index0 = len+1:nn;
[xL,xU,tlp] = cplex_bnd_solve(AA, bb, INDEQ, LB, UB, index0);
L(index0) = xL;
U(index0) = xU;
timeLP = timeLP + tlp;


%%--------------------------------------------
%% Formulate the KKT system, turn the problem
%% into one with A x == b, x >= 0 constraints
%% and x's upper bounds is one is implied.
%%
%% The order of the variables are:
%% ( x, s, wB, lambda, y, zL, zB, rB) 
%%--------------------------------------------


%% Formulating new A
L = [L(1:n); L(len+1:end)];
U = [U(1:n); U(len+1:end)];

return

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


function [H,f,A,b,Aeq,beq,LB,UB,cons,sstruct,timeLP] = refm1(H,f,A,b,Aeq,beq,LB,UB,cons,sstruct)
%% REF1 perform the first reformulation in appendix of the paper
m = size(A,1);
n = size(H,1);
meq = size(Aeq,1);
idxU = find((isfinite(LB)==0) & (isfinite(UB)==1));

timeLP = 0;
%% Change of variable: new var = UB(idxU) - x(idxU) >=0 
%% Original variable has no lower bounds, new variable has no upper bounds

if ~isempty(idxU)
  ub = UB(idxU);
  %% track change: 2
  sstruct.ub2 = ub;
  sstruct.idxU2 = idxU;
  hh = H(idxU,idxU);
  fidxU = f(idxU);
  f(idxU) = -fidxU;
  idxUc = setdiff(1:n,idxU);
  cons = cons + 0.5*ub'*hh*ub + fidxU'*ub;
  f(idxU) = f(idxU) - hh*ub;
  f(idxUc) = f(idxUc) + H(idxUc,idxU)*ub;
  H(idxUc,idxU) = - H(idxUc,idxU);
  H(idxU,idxUc) = - H(idxU,idxUc);
  if m > 0
    b = b - A(:,idxU)*ub;
    A(:,idxU) = -A(:,idxU);
  end
  if meq > 0
    beq = beq - Aeq(:,idxU)*ub;
    Aeq(:,idxU) = - Aeq(:,idxU);
  end
  LB(idxU) = 0;
  UB(idxU) = inf;
end

%% Shift the finite lower bounds to zero
idxL = find(isfinite(LB)==1);
if ~isempty(idxL)
  %% track change: 3
  sstruct.idxL3 = idxL;
  sstruct.lb3 = LB(idxL);
  [f,b,beq,LB,UB,cons] = shift(H,f,A,b,Aeq,beq,LB,UB,cons,idxL);
end

%% Scale so that the upper bound is 1
idxU = find(isfinite(UB)==1);
if ~isempty(idxU)
  %% track change: 4
  sstruct.idxU4 = idxU;
  sstruct.ub4 = UB(idxU);
  [H,f,A,Aeq,UB] = scale(H,f,A,Aeq,UB,idxU);
end


m = size(A,1);
n = size(H,1);
meq = size(Aeq,1);

%% If not all the bounds are finite, then calculate bounds and turn it to [0,1]

if (sum(isfinite(LB))<n) | (sum(isfinite(UB))<n)

  AA = [ A; Aeq];
  bb = [ b; beq];
  if meq == 0
      INDEQ = [];
  else
      INDEQ = m+1:m+meq;
  end

  idxL = find(isfinite(LB)==0);
  idxU = find(isfinite(UB)==0);

  if m + meq > 0    

      %% If AA is empty, then feeding AA and bb to CPLEXINT will result
      %% in error, and thus we only solve the following LPs when AA is not empty
     

     [xL,xU,tlp] = cplex_bnd_solve(AA, bb, INDEQ, LB, UB, idxL,'l');
     LB(idxL) = xL;
     timeLP = timeLP + tlp;

     [xL,xU,tlp] = cplex_bnd_solve(AA, bb, INDEQ, LB, UB, idxU,'u');
     UB(idxU) = xU;
     timeLP = timeLP + tlp;
   else
      
      %% In the case m + meq = 0, have to have finite bounds on LB and UB
      
      if length(LB)*length(UB) == 0 | sum(isinf([LB;UB])) > 0
          error('Both LB and UB must be finite.');
      end
  end
  %% track change: 5
  sstruct.idxL5 = idxL;
  sstruct.lb5 = LB(idxL);
  [f,b,beq,LB,UB,cons] = shift(H,f,A,b,Aeq,beq,LB,UB,cons,idxL);
  
  sstruct.idxU5 = idxU;
  sstruct.ub5 = UB(idxU);
  [H,f,A,Aeq,UB] = scale(H,f,A,Aeq,UB,idxU);

  %% We have calculated all the bounds and scaled them to [0,1]. But to have less complementarities,
  %% we will pretend that we did not find bounds for the original unbounded values.
  LB(idxL) = -inf;
  UB(idxU) = inf;
end

return


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function [f,b,beq,LB,UB,cons] = shift(H,f,A,b,Aeq,beq,LB,UB,cons,idxL)
%% SHIFT shifts L(idxL) to zero.

m = size(A,1);
n = size(H,1);
meq = size(Aeq,1);

if ~isempty(idxL)
  lb = LB(idxL);
  cons = cons + 0.5*lb'*H(idxL,idxL)*lb + f(idxL)'*lb;
  f(idxL)= f(idxL) + H(idxL,idxL)*lb;
  idxLc = setdiff(1:n,idxL);
  f(idxLc) = f(idxLc) + H(idxLc,idxL)*lb;

  if m > 0
    b = b - A(:,idxL)*lb;
  end
  if meq > 0
    beq = beq - Aeq(:,idxL)*lb;
  end

  UB(idxL) = UB(idxL) - lb;
  LB(idxL) = 0;
end

return

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function [H,f,A,Aeq,UB] = scale(H,f,A,Aeq,UB,idxU)
%% SCALE scales the part of UB indexed by 'idxU' to 1, assuming that LB(idxU)==0
m = size(A,1);
n = size(H,1);
meq = size(Aeq,1);

if ~isempty(idxU)
  idxUc = setdiff(1:n,idxU);
  ub = UB(idxU);
  H(idxU,idxU) = diag(ub)*H(idxU,idxU)*diag(ub);
  H(idxUc,idxU) = H(idxUc,idxU)*diag(ub);
  H(idxU,idxUc) = diag(ub)*H(idxU,idxUc);
  f(idxU) = ub .* f(idxU);
  if m > 0
    A(:,idxU) = A(:,idxU)*diag(ub);
  end
  if meq > 0
    Aeq(:,idxU) = Aeq(:,idxU)*diag(ub);
  end
  UB(idxU) = 1;
end

return

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


function checkinput(H,f,A,b,Aeq,beq,LB,UB)

%% Begin: Basic input checks

if size(H,1)*size(H,2) == 0 || norm(H,'fro') == 0
    error('H should be nonzero.');
end

if length(find(UB < LB)) > 0
    error('Need UB >= LB.');
end

if size(LB,2) > 1 | size(UB,2) > 1
    error('Both LB and UB must be column vectors.')
end

%% Commented out because we it is not needed anymore
%   if length(LB)*length(UB) == 0 | sum(isinf([LB;UB])) > 0
%     error('Both LB and UB must be finite.');
%   end

%% Commented out for large problems
%   if 2*size(H,1) + length(b) > 50
%     error('Problem too big right now.');
%   end


%% End: Basic input checks

return

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function x = project(x0,A,b,L,U)

[m,n] = size(A);

%[x,tt,solstat,details] = cplexint(2*eye(n), -2*x0,...
%                           A, b, [1:m], [], ...
%                           L, U, [], ...
%                           [], []);

x = quadprog(2*eye(n),-2*x0,[],[],A,b,L,U);

% solstat
% details

return

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function yes_or_no = isfeasible(A,b,L,U)

[m,n] = size(A);

%[x,tmp,solstat,details] = cplexint([], zeros(n,1),...
%                           A, b, [1:m], [], ...
%                           L, U, [], ...
%                           [], []);

[x,tmp,exitflag,output] = cplexlp(zeros(n,1),[],[],A,b,L,U);

% solstat
if output.cplexstatus ~= 1 
  yes_or_no = 0;
else
  yes_or_no = 1;
end

return
    
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


function [local_A,local_b] = fixedAb(A,b,L,U)

tol = 1.0e-15;

[m,n] = size(A);

local_A = A;
local_b = b;

I = find( abs(U - L) < tol );

for i = 1:length(I)
  j = I(i);
  local_b = local_b - U(j)*local_A(:,j);
  local_A(:,j) = zeros(m,1);
end

tmp = eye(n);
tmp = tmp(I,:);
local_A = [local_A;tmp];
local_b = [local_b;U(I)];

return


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

function [xLB,xUB,time] = cplex_bnd_solve( AA, bb, INDEQ, LB, UB, index, flag)
%% CPLEX_BND_SOLVE finds the lower and upper bounds for variables involved in the following feasible region:
%  { x | AA * x <= bb , LB <= x <= UB }
%  
%  where the equality holds for those indices identified by INDEQ, ie, AA(INDEQ,:) * x == bb(INDEQ).
%
% Parameters:
%       - index: we only calculate bounds for x(index), not on the other compnents of x. 
%       - flag: can take three values:
%               1) 'l': only lower bounds
%               2) 'u': only upper bounds
%               3) 'b': both lower and upper bounds, default
tStart = tic;

if numel(index) == 0
  xLB = [];
  xUB = [];
  time = toc(tStart);
  return
end

if nargin < 7
  flag = 'b';
end

% initilize data 
n = length(LB);
meq = length(INDEQ);
mm = length(bb);
m = mm - meq;
nn = length(index);

% set bound default values
if strcmp(flag,'l')|strcmp(flag,'b')
  xLB = LB(index);
else
  xLB = [];
end

if strcmp(flag,'u')|strcmp(flag,'b')
  xUB = UB(index);
else
  xUB = [];
end


% setup the first LP

lhs = -inf(mm,1);
lhs(INDEQ) = bb(INDEQ);

ff = zeros(n,1); ff(index(1)) = 1;

cplex = Cplex('lpbnd');
cplex.DisplayFunc = [];
cplex.Model.obj   = ff;
cplex.Model.lb    = LB;
cplex.Model.ub    = UB;
cplex.Model.A     = AA;
cplex.Model.lhs   = lhs;
cplex.Model.rhs   = bb;

% solve first lower bound
if strcmp(flag,'l')|strcmp(flag,'b')
  cplex.Model.sense = 'minimize';
  cplex.solve();
  if  cplex.Solution.status ~= 1
    fprintf('1st LP lower bound cannot be obtained: either unbounded or infeasible!');
    error('CPLEX solution status = %d',cplex.Solution.status);
  end
  xx1 = cplex.Solution.x;
  xLB(1) = ff'*xx1;
end

% solve first upper bound
if strcmp(flag,'u')|strcmp(flag,'b')
  cplex.Model.sense = 'maximize';
  cplex.solve();
  if  cplex.Solution.status ~= 1
     fprintf('1st LP upper bound cannot be obtained: either unbounded or infeasible!');
     error('CPLEX solution status = %d',cplex.Solution.status);
  end
  xx2 = cplex.Solution.x;
  xUB(1) = ff'*xx2;
end

% find the indices of xx1 and xx2 are at its lower or upper bounds, no need to solve those LPs
if strcmp(flag,'b')
  tmp_L = min(xx1,xx2);
  tmp_U = max(xx1,xx2);
elseif strcmp(flag,'l')
  tmp_L = xx1;
else
  tmp_U = xx2;
end

if strcmp(flag,'l')|strcmp(flag,'b')
  tmp_L = tmp_L(index);
  idx_L = find(abs(tmp_L - LB(index)) < 1e-8);
  index_L = index;
  index_L(idx_L) = 0;
end

if strcmp(flag,'u')|strcmp(flag,'b')
  tmp_U = tmp_U(index);
  idx_U = find(abs(tmp_U - UB(index)) < 1e-8);
  index_U = index;
  index_U(idx_U) = 0;
end


colstat = cplex.Solution.basis.colstat;
rowstat = cplex.Solution.basis.rowstat;

% use primal simplex method

cplex.Param.lpmethod.Cur = 1;


% solve upper bounds

if strcmp(flag,'b')|strcmp(flag,'u')
  cplex.Model.sense = 'maximize';
  for i = 2:nn
    if index_U(i) > 0
      ff = zeros(n,1);
      ff(index_U(i)) = 1;
      cplex.Model.obj = ff;
      cplex.Start.basis.colstat = colstat;
      cplex.Start.basis.rowstat = rowstat;
      cplex.solve();

      if cplex.Solution.status ~=  1
        fprintf('%d-th LP upper bound cannot be obtained: either unbounded or infeasible',i);
        error('CPLEX solution status = %d',cplex.Solution.status);
      end
      xUB(i)= ff'*cplex.Solution.x;
      colstat = cplex.Solution.basis.colstat;
      rowstat = cplex.Solution.basis.rowstat;
    end
  end
end


% solve lower bounds

if strcmp(flag,'b')|strcmp(flag,'l')

  cplex.Model.sense = 'minimize';

  for i = 2:nn
    if index_L(i) > 0
      ff = zeros(n,1);
      ff(index_L(i)) = 1;
      cplex.Model.obj = ff;
      cplex.Start.basis.colstat = colstat;
      cplex.Start.basis.rowstat = rowstat;
      cplex.solve();

      if cplex.Solution.status ~=  1
        fprintf('%d-th LP lower bound cannot be obtained: either unbounded or infeasible',i);
        error('CPLEX solution status = %d',cplex.Solution.status);
      end
      xLB(i)= ff'*cplex.Solution.x;
      colstat = cplex.Solution.basis.colstat;
      rowstat = cplex.Solution.basis.rowstat;
    end
  end
end

time = toc(tStart);
return
