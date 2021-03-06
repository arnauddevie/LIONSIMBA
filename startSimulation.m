%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% This code was written by Marcello Torchio, University of Pavia.
% Please send comments or questions to
% marcello.torchio01@ateneopv.it
%
% Copyright 2015: 	Marcello Torchio, Lalo Magni, and Davide M. Raimondo, University of Pavia
%					Bhushan Gopaluni, University of British Columbia
%                 	Richard D. Braatz, MIT.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% STARTSIMULATION  Starts the simulation of the Li-ion battery.
%
%   RESULTS = STARTSIMULATION(t0,tf,initialStates,I,startParameters)
%   Starts the simulation of the Li-ion Cell with LIONSIMBA.
%
%   Input:
%       - t0 : initial integration time
%       - tf : final integration time
%       - initialStates : structure containing data for initializing the
%       states of the battery.
%       - I  : Applied current density. If negative the battery gets
%       discharged, if positive gets charged.
%       - startParameters : if provider, it defines the cell array containing the parameters
%       structures to be used in the simulation. Every single structure has to be obtained through the Parameters_init script.
%		If a cell array of N parameters structures is used, the simulator will perform a simulation with N cells in series.
%		If a cell of 1 parameters structure is used, then a single cell will be simulated.
%
%   Output:
%       - results : structure containing the solution of the dependent
%       variables. The stored results have as many rows as time instants
%       and columns as number of discrete volumes. If multiple cells are
%       simulated, the index i is used to access to the data of the i-th
%       cell.
%
%     results.Phis{i}:                      Solid Phase potential
%     results.Phie{i}:                      Liquid Phase potential
%     results.ce{i}:                        Electrolyte concentration
%     results.cs_surface{i}:                Electrode surface concentration
%     results.cs_average{i}:                Electrode average concentration
%     results.time{i}:                      Interpolated simulation time
%     results.int_internal_time{i}:         Integrator time steps
%     results.ionic_flux{i}:                Ionic flux
%     results.side_reaction_flux{i}:        Side reaction flux
%     results.SOC{i}:                       State of Charge
%     results.SOC_estimated{i}:             State of Charge estimate according to the
%                                           user-defined function
%     results.Voltage{i}:                   Cell voltage
%     results.Temperature{i}:               Cell Temperature
%     results.Qrev{i}:                      Reversible heat generation rate
%     results.Qrxn{i}:                      Reaction heat generation rate
%     results.Qohm{i}:                      Ohmic heat generation rate
%     results.film{i}:                      Side reaction film resistance
%     results.R_int{i}:                     Internal resistance
%     results.Up{i}:                        Cathode open circuit potential
%     results.Un{i}:                        Anode open circuit potential
%     results.etap{i}:                      Cathode overpotential
%     results.etan{i}:                      Anode overpotential
%     results.parameters{i}:                Parameters used for the simulation
%

function results = startSimulation(t0,tf,initialState,I,startParameters)

try
    test_lionsimba_folder
catch
    error('It seems that you did not add to the Matlab path the battery_model_files directory and the folders therein. Please fix this problem and restart the simulation.')
end

% Version of LIONSIMBA
version       = '1.021b';

if(isempty(startParameters))
    % Load battery's parameters if not provided by the user
    param{1} = Parameters_init;
else
    % Use user provided parameters
    param = startParameters;
end

% Check the input current value.
if(param{1}.AppliedCurrent==1)
    if(~isreal(I) || isnan(I) || isinf(I) || isempty(I))
        error('The input current provided is a complex value or NaN. Please check the value and restart.')
    end
end

% Check for environmental tool availability
checkEnvironment(param{1},nargin);

% For each parameter structure, check if all the fields are set.
for i=1:length(param)
    %Check if the parameters have been set correctly
    [result, missing] = checkBatteryParameters(param{i});
    if(result==0)
        disp('Warning, there are missing parameters in the param array.')
        disp('Here below there is the list of such parameters:')
        for jj=1:length(missing)
            disp(missing{jj});
        end
        error('Please fix the problem and restart the script')
    end
end

if(param{1}.PrintHeaderInfo==1)
    clc
    fprintf('/------------------------------------\\\n')
    fprintf('|                                    |\n')
    fprintf('|            LIONSIMBA               |\n')
    fprintf('|            Tooblbox                |\n')
    fprintf('|            version %s          |\n',version)
    fprintf('|                                    |\n')
    fprintf('\\------------------------------------/\n')
    fprintf('Copyright (C) 2015-%d by M.Torchio, L.Magni, B.Gopaluni, R.D.Braatz and D.M.Raimondo\n\n',str2double(datestr(now,'yyyy'))+1)
    fprintf('Send bug reports, questions or comments to marcello.torchio01@ateneopv.it\n')
    fprintf('Updates available at the web page http://sisdin.unipv.it/labsisdin/lionsimba.php\n\n')
end

% If everything is ok, let's start to simulate.
results = mainCore(t0,tf,initialState,I,param);
end



function results = mainCore(t0,tf,initialState,I,param)

% Store the original parameters structure in order to return it after the
% end of the simulations.
param_original  = param;

% Get the total number of cells that have to be simulated.
n_cells         = length(param);

% Check if more cells are simulated when potentiostatic conditions are
% required.
if(param{1}.AppliedCurrent==3 && n_cells~=1)
    clc
    error('!!!ERROR!!! -- Potentiostatic simulations are only possible with single cell packs -- !!!ERROR!!!')
end

% Check if the initial state structure is given
[Y0_existence,YP0_existence,Y0,YP0] = checkInitialStates(initialState);

% Switch among the selected operating modes defining suitable getCurr
% function. If multiple cells are required, the variable current profile
% or its constant value are retreived from the first element of the
% parameters structures. This is valid because, when multiple cells are
% connected in series, they are crossed by the same amount of current.
switch(param{1}.AppliedCurrent)
    case 2
        param{1}.getCurr = param{1}.CurrentFunction;
    otherwise
        param{1}.getCurr = @(t,t0,tf,extra)I;
end

% Define absolute and relative tolerances. If more cells are required,
% these values are taken from the first parameters structure.
opt.AbsTol      = param{1}.AbsTol;
opt.RelTol      = param{1}.RelTol;

% The Matlab function fsolve is used to initially solve the algebraic
% equations by keeping constant the differential ones to their initial
% values at t0.
opt_fsolve              = optimset;
opt_fsolve.Display      = 'off';
opt_fsolve.FunValCheck  = 'on';

n_diff          = zeros(n_cells,1);
n_alg           = zeros(n_cells,1);
start_x_index   = 1;

% For each cell, allcoate memory to store external functions used to
% estimate the SOC.
SOC_estimate    = cell(n_cells,1);

% Perform several checks over the cells
for i=1:n_cells
    % When Fick's law of diffusion is used, at least 10 discretization
    % points are required. Raise an error if this condition is not met.
    if((param{i}.Nr_p<10 || param{i}.Nr_n<10) && param{i}.SolidPhaseDiffusion==3)
        error('The number of discrete points for the paricles must be at least 10 in both cathode and anode.')
    end
    % Check if the SOC estimation function handle have been set. In case that
    % the funciton handle has not been defined or it does not have the right
    % number of input arguments, then return empty values.
    if(isempty(param{i}.SOC_estimation_function) || nargin(param{i}.SOC_estimation_function)~=6)
        SOC_estimate{i} = @(a,b,c,d,e,f,g,h,i,j,k)[];
    else
        SOC_estimate{i} = @SOCestimation;
    end
    param{i}.Nsum      = param{i}.Np + param{i}.Ns + param{i}.Nn;
    param{i}.Nsum_nos  = param{i}.Np + param{i}.Nn;
    
    % Define the discretization steps.
    param{i}.deltax_al     = 1 / param{i}.Nal;
    param{i}.deltax_p      = 1 / param{i}.Np;
    param{i}.deltax_s      = 1 / param{i}.Ns;
    param{i}.deltax_n      = 1 / param{i}.Nn;
    param{i}.deltax_co     = 1 / param{i}.Nco;
    
    % Store the indices of the unknown variables
    param{i}.ce_indices         = (1:param{i}.Nsum);
    
    % Modify the solid phase indices according to the model used. If Fick's
    % law is used, then it is necessary to account also for the diffusion
    % inside the solid particles.
    if(param{i}.SolidPhaseDiffusion==1 || param{i}.SolidPhaseDiffusion==2)
        param{i}.cs_average_indices = (param{i}.ce_indices(end)+1:param{i}.ce_indices(end)+param{i}.Np+param{i}.Nn);
    elseif(param{i}.SolidPhaseDiffusion==3)
        param{i}.cs_average_indices = (param{i}.ce_indices(end)+1:param{i}.ce_indices(end)+param{i}.Np*param{i}.Nr_p+param{i}.Nn*param{i}.Nr_n);
    end
    
    param{i}.T_indices          = (param{i}.cs_average_indices(end)+1:param{i}.cs_average_indices(end)+param{i}.Nal+param{i}.Nsum+param{i}.Nco);
    param{i}.film_indices       = (param{i}.T_indices(end)+1:param{i}.T_indices(end)+param{i}.Nn);
    param{i}.Q_indices          = (param{i}.film_indices(end)+1:param{i}.film_indices(end)+param{i}.Np+param{i}.Nn);
    
    
    param{i}.jflux_indices      = (param{i}.Q_indices(end)+1:param{i}.Q_indices(end)+param{i}.Np+param{i}.Nn);
    param{i}.Phis_indices       = (param{i}.jflux_indices(end)+1:param{i}.jflux_indices(end)+param{i}.Np+param{i}.Nn);
    param{i}.Phie_indices       = (param{i}.Phis_indices(end)+1:param{i}.Phis_indices(end)+param{i}.Np+param{i}.Ns+param{i}.Nn);
    param{i}.js_indices         = (param{i}.Phie_indices(end)+1:param{i}.Phie_indices(end)+param{i}.Nn);
    param{i}.Iapp_indices       = (param{i}.js_indices(end)+1);
    
    % Phis matrices preallocation. Given that in the proposed code the
    % solid phase conductivity is considered to be constant across the cell
    % length, the discretization matrices can be assembled only once and
    % used later in the code.
    
    % A matrix for the positive electrode
    c = ones(param{i}.Np-1,1);
    d = -2*ones(param{i}.Np,1);
    
    A_p 				= gallery('tridiag',c,d,c);
    A_p(1,1) 			= -1;
    A_p(end,end-1:end) 	= [1 -1];
    
    % A matrix for the negative electrode
    c = ones(param{i}.Nn-1,1);
    d = -2*ones(param{i}.Nn,1);
    
    A_n 			= gallery('tridiag',c,d,c);
    A_n(1,1) 		= -1;
    A_n(end,end) 	= -1;
    
    % Store the matrices in the param structure for future usage for each
    % cell in the pack.
    param{i}.A_p = A_p;
    param{i}.A_n = A_n;
    
    % Precompute the discretization points for the solid particles.
    % These data will be used when Fick's law of diffusion is considered.
    param{i}.Rad_position_p  = linspace(0,param{i}.Rp_p,param{i}.Nr_p)';
    param{i}.Rad_position_n  = linspace(0,param{i}.Rp_n,param{i}.Nr_n)';
    
    % Precompute the matrices used for the numerical differentiation. These matrices
    % will be used when Fick's law is considered.
    [param{i}.FO_D_p,param{i}.FO_D_c_p] = firstOrderDerivativeMatrix(0,param{i}.Rp_p,param{i}.Nr_p);
    [param{i}.FO_D_n,param{i}.FO_D_c_n] = firstOrderDerivativeMatrix(0,param{i}.Rp_n,param{i}.Nr_n);
    
    % Precompute the matrices used for the numerical differentiation. These matrices
    % will be used when Fick's law is considered.
    [param{i}.SO_D_p,param{i}.SO_D_c_p,param{i}.SO_D_dx_p] = secondOrderDerivativeMatrix(0,param{i}.Rp_p,param{i}.Nr_p);
    [param{i}.SO_D_n,param{i}.SO_D_c_n,param{i}.SO_D_dx_n] = secondOrderDerivativeMatrix(0,param{i}.Rp_n,param{i}.Nr_n);
    
    % Init the value of the injected current.
    param{i}.I = param{1}.getCurr(0,t0,tf,param{1}.extraData);
    
    %% Initial conditions
    % Initial differential states
    % Check the type of model used for solid diffusion
    if(param{i}.SolidPhaseDiffusion==1 || param{i}.SolidPhaseDiffusion==2)
        % This initialization is used when reduced models are employed
        cs_average_init     = [param{i}.cs_p_init*ones(param{i}.Np,1);param{i}.cs_n_init*ones(param{i}.Nn,1)];
    elseif (param{i}.SolidPhaseDiffusion==3)
        % If the full model is used (Fick's law), then the initial conditions are
        % modified in order to account for the solid phase diffusion
        % equation structure.
        cs_average_init     = [param{i}.cs_p_init*ones(param{i}.Np*param{i}.Nr_p,1);param{i}.cs_n_init*ones(param{i}.Nn*param{i}.Nr_n,1)];
    end
    % Initial values for the other differential variables.
    ce_init             = param{i}.ce_init*[ones(param{i}.Np,1);ones(param{i}.Ns,1);ones(param{i}.Nn,1)];
    T_init              = param{i}.T_init * ones(param{i}.Nsum+param{i}.Nal+param{i}.Nco,1);
    film_init           = zeros(param{i}.Nn,1);
    Q_init              = zeros(param{i}.Np+param{i}.Nn,1);
    
    % Store the number of differential variables in each cell.
    n_diff(i) = sum([length(cs_average_init) length(ce_init) length(T_init) length(film_init) length(Q_init)]);
    
    % Initial guess for the algebraic variables
    jflux_init          = [-0.43e-5*ones(param{i}.Np,1);0.483e-5*ones(param{i}.Nn,1)];
    Phis_init           = [4.2*ones(param{i}.Np,1);0.074*ones(param{i}.Nn,1)];
    Phie_init           = zeros(param{i}.Nsum,1);
    js_init             = 0.483e-5*ones(param{i}.Nn,1);
    I_app               = 1;
    
    % Build the array of algebraic initial conditions
    x0_alg              = [
        jflux_init;...
        Phis_init;...
        Phie_init;...
        js_init;...
        I_app
        ];
    
    n_alg(i) = length(x0_alg);
    
    % Store the number of differential and algebraic variables for each cell.
    param{i}.ndiff = n_diff(i);
    param{i}.nalg  = n_alg(i);
    
    if((Y0_existence==0) && (YP0_existence==0))
        % Solve the algebraic equations to find a set of semi-consistent initial
        % conditions for the algebraic equations. This will help the DAE solver as
        % a warm startup.
        [init_point,~,~,~,~] = fsolve(@algebraicStates,x0_alg,opt_fsolve,ce_init,cs_average_init,Q_init,T_init,film_init,param{i});
        
        % Build the initial values array for the integrator
        Yt0 = [ce_init;cs_average_init;T_init;film_init;Q_init;init_point];
        Y0  = [Y0;Yt0];
        YP0 = [YP0;zeros(size(Yt0))];
    end
    % The x_index variable will be used in the battery model file in
    % order to distinguish among the different variables.
    param{i}.x_index    = (start_x_index:n_diff(i)+n_alg(i)+start_x_index-1);
    %     param{i}.T_indices  = T_indices;
    start_x_index       = n_diff(i)+n_alg(i)+start_x_index;
end

if(n_cells==1)
    nc = ' cell';
else
    nc = ' cells';
end

disp(['Finding a set of consistent ICs for ',num2str(n_cells),nc,' battery pack. Please wait..'])

% Empty the used arrays
ce_t            = cell(n_cells,1);
cs_bar_t        = cell(n_cells,1);
T_t             = cell(n_cells,1);
jflux_t         = cell(n_cells,1);
Phis_t          = cell(n_cells,1);
Phie_t          = cell(n_cells,1);
cs_star_t       = cell(n_cells,1);
t_tot           = cell(n_cells,1);
Qrev_t          = cell(n_cells,1);
Qrxn_t          = cell(n_cells,1);
Qohm_t          = cell(n_cells,1);
SOC_t           = cell(n_cells,1);
Voltage_t       = cell(n_cells,1);
SOC_estimated_t = cell(n_cells,1);
film_t          = cell(n_cells,1);
js_t            = cell(n_cells,1);
R_int_t         = cell(n_cells,1);
app_current_t   = cell(n_cells,1);
Up_t            = cell(n_cells,1);
Un_t            = cell(n_cells,1);
etap_t          = cell(n_cells,1);
etan_t          = cell(n_cells,1);
dudtp_t         = cell(n_cells,1);
dudtn_t         = cell(n_cells,1);
Q_t             = cell(n_cells,1);
yp_original     = YP0';

% This flag is used to notify the reason of the simulation stop. If 0
% everything went well.
exit_reason     = 0;
% Define the structure to be passed to the residual function
dati.param  = param;
dati.t0     = t0;
dati.tf     = tf;

% Define algebraic and differential variables. 1-> differential variables,
% 0-> algebraic variables.
id = [];
for i=1:n_cells
    id = [id;ones(n_diff(i),1);zeros(n_alg(i),1)];
end

% Define the options for Sundials
options = IDASetOptions('RelTol',opt.RelTol,...
    'AbsTol',opt.AbsTol,...
    'MaxNumSteps',1500,...
    'VariableTypes',id,...
    'UserData',dati);

% Init the solver
IDAInit(@batteryModel,t0,Y0,YP0,options);
% Find consistent initial conditions
[~, yy, ~] = IDACalcIC(t0+10,'FindAlgebraic');

% Init the starting integration time
t = t0;

% Store in the results the initial states values.
y = yy';

[ce_t,cs_bar_t,T_t,jflux_t,Phis_t, Phie_t, cs_star_t, SOC_t, film_t, js_t,Up_t,Un_t,R_int_t,app_current_t,Voltage_t,SOC_estimated_t,Qrev_t,Qrxn_t,Qohm_t,Q_t,~,dudtp_t, dudtn_t,t_tot] =...
    storeSimulationResults(n_cells,ce_t,cs_bar_t,T_t,jflux_t,Phis_t, Phie_t, cs_star_t, SOC_t, film_t, js_t,app_current_t,Voltage_t,SOC_estimated_t,Up_t,Un_t,R_int_t,Qrev_t,Qrxn_t,Qohm_t,Q_t,dudtp_t, dudtn_t, t_tot, y, t,SOC_estimate,t0,tf, param);
% Start timing control
sim_time = 0;
% Loop until the integration time reaches tf.
while(t<tf)
    %% Check stop conditions for each cell
    for i=1:n_cells
        voltage = Phis_t{i}(end,1)-Phis_t{i}(end,end);
        Sout    = internalSOCestimate(cs_bar_t,param,i);
        % Break conditions.
        if(voltage<param{i}.CutoffVoltage)
            disp(['Cell #',num2str(i),' below its Cutoff voltage. Stopping']);
            exit_reason = 1;
        end
        
        if(voltage>param{i}.CutoverVoltage)
            disp(['Cell #',num2str(i),' above its Cutover voltage. Stopping']);
            exit_reason = 2;
        end
        
        if(Sout<param{i}.CutoffSOC)
            disp(['Cell #',num2str(i),' below its Cutoff SOC. Stopping']);
            exit_reason = 3;
        end
        
        if(Sout>param{i}.CutoverSOC)
            disp(['Cell #',num2str(i),' above its Cutover SOC. Stopping']);
            exit_reason = 4;
        end
    end
    
    if(exit_reason~=0)
        break;
    end
    %% Solve the set of DAEs
    % The solver IDA is used to solve the resulting set of DAEs. Please
    % refer to IDA manual for more information about syntax and its usage.
    tic
    [~, t, y]   = IDASolve(tf,'OneStep');
    sim_time=sim_time+toc;
    y           = y';
    % Store derivative info at each time step
    yp_original = [yp_original;IDAGet('DerivSolution',t,1)'];
    
    [ce_t,cs_bar_t,T_t,jflux_t,Phis_t, Phie_t, cs_star_t, SOC_t, film_t, js_t,Up_t,Un_t,R_int_t,app_current_t,Voltage_t,SOC_estimated_t,Qrev_t,Qrxn_t,Qohm_t,Q_t,tot_voltage,dudtp_t, dudtn_t,t_tot] =...
        storeSimulationResults(n_cells,ce_t,cs_bar_t,T_t,jflux_t,Phis_t, Phie_t, cs_star_t, SOC_t, film_t, js_t,app_current_t,Voltage_t,SOC_estimated_t,Up_t,Un_t,R_int_t,Qrev_t,Qrxn_t,Qohm_t,Q_t,dudtp_t, dudtn_t, t_tot, y, t,SOC_estimate,t0,tf, param);
    
    % If the output scope is active, show additional information to the user
    if(param{1}.Scope==1)
        if(n_cells==1)
            temperature     = T_t{1}(end,end);
            % If Fick's law of diffusion is used, before to evaluate the
            % SOC, it is necessary to compute the average solid
            % concentration in each particle.
            Sout = internalSOCestimate(cs_bar_t,param,1);
            clc
            fprintf(['No. of cells in the pack \t',num2str(n_cells),'\n']);
            fprintf(['Time \t\t\t\t\t',num2str(t),' s\n']);
            % If potentiostatic mode is running, applied current comes as
            % solution of DAEs. Otherwise it is provided by the user.
            if(param{1}.AppliedCurrent==3)
                fprintf(['Applied current \t\t',num2str(y(end)),' A/m^2\n']);
            else
                fprintf(['Applied current \t\t',num2str(param{1}.getCurr(t,t0,tf,param{1}.extraData)),' A/m^2\n']);
            end
            fprintf(['Voltage \t\t\t\t',          num2str(Phis_t{1}(end,1)-Phis_t{1}(end,end)),   ' V\n']);
            fprintf(['Temperature \t\t\t',        num2str(temperature),                           ' K\n']);
            fprintf(['SOC \t\t\t\t\t',            num2str(Sout),                                  ' %% \n']);
            fprintf(['Cutoff Voltage \t\t\t',     num2str(param{1}.CutoffVoltage),                ' V\n']);
            fprintf(['Cutover Voltage \t\t',      num2str(param{1}.CutoverVoltage),               ' V\n']);
            fprintf(['Internal Resistance \t',    num2str(R_int_t{1}(end)),                       ' Ohm m^2\n']);
            fprintf(['Absolute tolerance \t\t',   num2str(param{1}.AbsTol),                       '\n']);
            fprintf(['Relative tolerance \t\t',   num2str(param{1}.RelTol),                       '\n']);
            fprintf(['Initial int. time \t\t',    num2str(t0),                                    ' s\n']);
            fprintf(['Final int. time \t\t',      num2str(tf),                                    ' s\n']);
            fprintf(['N. of unknowns \t\t\t',     num2str(length(y)),                             ' \n']);
        else
            clc
            fprintf(['No. of cells in the pack \t',num2str(n_cells),'\n']);
            fprintf(['Time \t\t\t\t\t',num2str(t),' s\n']);
            % If potentiostatic mode is running, applied current comes as
            % solution of DAEs. Otherwise it is provided by the user.
            if(param{1}.AppliedCurrent==3)
                fprintf(['Applied current \t\t',num2str(y(end)),' A/m^2\n']);
            else
                fprintf(['Applied current \t\t',num2str(param{1}.getCurr(t,t0,tf,param{1}.extraData)),' A/m^2\n']);
            end
            
            fprintf(['Voltage \t\t\t\t',          num2str(tot_voltage),       ' V\n']);
            fprintf(['Absolute tolerance \t\t',   num2str(param{1}.AbsTol),   ' \n']);
            fprintf(['Relative tolerance \t\t',   num2str(param{1}.RelTol),   ' \n']);
            fprintf(['Initial int. time \t\t',    num2str(t0),                ' s\n']);
            fprintf(['Final int. time \t\t',      num2str(tf),                ' s\n']);
            fprintf(['N. of unknowns \t\t\t',     num2str(length(y)),         ' \n']);
        end
    end
end

disp(['Elasped time: ',num2str(sim_time),' s']);

% Interpolate for fixed time step values
t_tot_original = t_tot;


% Build the time vector used for interpolation
time_vector = (t0:param{i}.integrationStep:tf);

% In case of the simulation has stopped before the final time set by the
% user, change the tf variable in order to interpolate only available
% values.

if(t<tf)
    % Set final time equal to the last integration step
    tf          = t;
    % Redefine the time vector used for interpolation
    time_vector = (t0:param{i}.integrationStep:tf);
end

% If at least one integration step has been done, retreive the first order
% time derivative information. Otherwise use the initial data.
if(time_vector(end)>t0)
    % Retreive derivative information at the last time step
    yp          = interp1(t_tot{i},yp_original,time_vector(end))';
    % After interpolating, delete all the other data.
    yp_original = yp_original(end,:)';
else
    % If the integration step carried out by SUNDIALS is less than the
    % parametrized step size, then return the initial data as set of
    % initial states.
    yp          = YP0;
    yp_original = YP0;
end

% Free memory allocated by IDA solver
IDAFree

% These variables will be used to store the original results of the
% integration process.
Phis_t_o            = cell(n_cells,1);
Phie_t_o            = cell(n_cells,1);
ce_t_o              = cell(n_cells,1);
cs_star_t_o         = cell(n_cells,1);
cs_average_t_o      = cell(n_cells,1);
jflux_t_o           = cell(n_cells,1);
SOC_t_o             = cell(n_cells,1);
T_t_o               = cell(n_cells,1);
Voltage_t_o         = cell(n_cells,1);
SOC_estimated_t_o   = cell(n_cells,1);
film_t_o            = cell(n_cells,1);
js_t_o              = cell(n_cells,1);
R_int_t_o           = cell(n_cells,1);
Up_t_o              = cell(n_cells,1);
Un_t_o              = cell(n_cells,1);
dudtp_t_o           = cell(n_cells,1);
dudtn_t_o           = cell(n_cells,1);
Qrev_t_o            = cell(n_cells,1);
Qrxn_t_o            = cell(n_cells,1);
Qohm_t_o            = cell(n_cells,1);
etap_t_o            = cell(n_cells,1);
etan_t_o            = cell(n_cells,1);
app_current_t_o     = cell(n_cells,1);
Q_t_o               = cell(n_cells,1);
y                   = [];
y_original          = [];
for i=1:n_cells
    % Save the overpotentials
    etap_t{i} = Phis_t{i}(:,1:param{i}.Np)-Phie_t{i}(:,1:param{i}.Np)-Up_t{i};
    if(param{i}.EnableAgeing==1)
        etan_t{i} = Phis_t{i}(:,param{i}.Np+1:end)-Phie_t{i}(:,param{i}.Np+param{i}.Ns+1:end)-Un_t{i} - param{1}.F*jflux_t{i}(:,param{i}.Np+1:end).*(param{i}.R_SEI+film_t{i}./param{i}.k_n_aging);
    else
        etan_t{i} = Phis_t{i}(:,param{i}.Np+1:end)-Phie_t{i}(:,param{i}.Np+param{i}.Ns+1:end)-Un_t{i};
    end
    if(param{i}.integrationStep>0)
        % Store original results
        Phis_t_o{i}            = Phis_t{i};
        Phie_t_o{i}            = Phie_t{i};
        ce_t_o{i}              = ce_t{i};
        cs_star_t_o{i}         = cs_star_t{i};
        cs_average_t_o{i}      = cs_bar_t{i};
        jflux_t_o{i}           = jflux_t{i};
        SOC_t_o{i}             = SOC_t{i};
        T_t_o{i}               = T_t{i};
        Voltage_t_o{i}         = Voltage_t{i};
        SOC_estimated_t_o{i}   = SOC_estimated_t{i};
        film_t_o{i}            = film_t{i};
        js_t_o{i}              = js_t{i};
        R_int_t_o{i}           = R_int_t{i};
        app_current_t_o{i}     = app_current_t{i};
        Up_t_o{i}              = Up_t{i};
        Un_t_o{i}              = Un_t{i};
        dudtp_t_o{i}           = dudtp_t{i};
        dudtn_t_o{i}           = dudtn_t{i};
        etap_t_o{i}            = etap_t{i};
        etan_t_o{i}            = etan_t{i};
        Qrev_t_o{i}            = Qrev_t{i};
        Qrxn_t_o{i}            = Qrxn_t{i};
        Qohm_t_o{i}            = Qohm_t{i};
        Q_t_o{i}               = Q_t{i};
        
        if(time_vector(end)>t0)
            % Interpolate the results
            Phis_t{i}          = interp1(t_tot{i},Phis_t{i},time_vector');
            Phie_t{i}          = interp1(t_tot{i},Phie_t{i},time_vector');
            ce_t{i}            = interp1(t_tot{i},ce_t{i},time_vector');
            cs_star_t{i}       = interp1(t_tot{i},cs_star_t{i},time_vector');
            cs_bar_t{i}        = interp1(t_tot{i},cs_bar_t{i},time_vector');
            jflux_t{i}         = interp1(t_tot{i},jflux_t{i},time_vector');
            SOC_t{i}           = interp1(t_tot{i},SOC_t{i},time_vector');
            SOC_estimated_t{i} = interp1(t_tot{i},SOC_estimated_t{i},time_vector');
            Voltage_t{i}       = interp1(t_tot{i},Voltage_t{i},time_vector');
            film_t{i}          = interp1(t_tot{i},film_t{i},time_vector');
            js_t{i}            = interp1(t_tot{i},js_t{i},time_vector');
            R_int_t{i}         = interp1(t_tot{i},R_int_t{i},time_vector');
            T_t{i}             = interp1(t_tot{i},T_t{i},time_vector');
            app_current_t{i}   = interp1(t_tot{i},app_current_t{i},time_vector');
            Up_t{i}            = interp1(t_tot{i},Up_t{i},time_vector');
            Un_t{i}            = interp1(t_tot{i},Un_t{i},time_vector');
            Qrev_t{i}          = interp1(t_tot{i},Qrev_t{i},time_vector');
            Qrxn_t{i}          = interp1(t_tot{i},Qrxn_t{i},time_vector');
            Qohm_t{i}          = interp1(t_tot{i},Qohm_t{i},time_vector');
            etap_t{i}          = interp1(t_tot{i},etap_t{i},time_vector');
            etan_t{i}          = interp1(t_tot{i},etan_t{i},time_vector');
            dudtp_t{i}         = interp1(t_tot{i},dudtp_t{i},time_vector');
            dudtn_t{i}         = interp1(t_tot{i},dudtn_t{i},time_vector');
            Q_t{i}             = interp1(t_tot{i},Q_t{i},time_vector');
            t_tot{i}           = time_vector';
        end
    end
    % Store results. If integration steps are enabled, store the interpolated
    % data.
    results.Phis{i}                        = Phis_t{i};
    results.Phie{i}                        = Phie_t{i};
    results.ce{i}                          = ce_t{i};
    results.cs_surface{i}                  = cs_star_t{i};
    results.cs_average{i}                  = cs_bar_t{i};
    results.time{i}                        = t_tot{i};
    results.int_internal_time{i}           = t_tot_original{i};
    results.ionic_flux{i}                  = jflux_t{i};
    results.side_reaction_flux{i}          = js_t{i};
    results.SOC{i}                         = SOC_t{i};
    results.SOC_estimated{i}               = SOC_estimated_t{i};
    results.Voltage{i}                     = Voltage_t{i};
    results.Temperature{i}                 = T_t{i};
    results.Qrev{i}                        = Qrev_t{i};
    results.Qrxn{i}                        = Qrxn_t{i};
    results.Qohm{i}                        = Qohm_t{i};
    results.film{i}                        = film_t{i};
    results.R_int{i}                       = R_int_t{i};
    results.Up{i}                          = Up_t{i};
    results.Un{i}                          = Un_t{i};
    results.etap{i}                        = etap_t{i};
    results.etan{i}                        = etan_t{i};
    results.dudtp{i}                       = dudtp_t{i};
    results.dudtn{i}                       = dudtn_t{i};
    results.Q{i}                           = Q_t{i};
    results.parameters{i}                  = param{i};
    
    % Store original data.
    results.original.Phis{i}               = Phis_t_o{i};
    results.original.Phie{i}               = Phie_t_o{i};
    results.original.ce{i}                 = ce_t_o{i};
    results.original.cs_surface{i}         = cs_star_t_o{i};
    results.original.cs_average{i}         = cs_average_t_o{i};
    results.original.ionic_flux{i}         = jflux_t_o{i};
    results.original.side_reaction_flux{i} = js_t_o{i};
    results.original.SOC{i}                = SOC_t_o{i};
    results.original.SOC_estimated{i}      = SOC_estimated_t_o{i};
    results.original.Voltage{i}            = Voltage_t_o{i};
    results.original.Temperature{i}        = T_t_o{i};
    results.original.film{i}               = film_t_o{i};
    results.original.R_int{i}              = R_int_t_o{i};
    results.original.Up{i}                 = Up_t_o{i};
    results.original.Un{i}                 = Un_t_o{i};
    results.original.etap{i}               = etap_t_o{i};
    results.original.etan{i}               = etan_t_o{i};
    results.original.Q{i}                  = Q_t_o{i};
    results.original.parameters{i}         = param_original{i};
    
    % Store initial states data
    y           = [y;ce_t{i}(end,:)';cs_bar_t{i}(end,:)';T_t{i}(end,:)';film_t{i}(end,:)';Q_t{i}(end,:)';jflux_t{i}(end,:)';Phis_t{i}(end,:)';Phie_t{i}(end,:)';js_t{i}(end,:)';app_current_t{i}(end)];
    % Store initial states original data
    y_original  = [y_original;ce_t_o{i}(end,:)';cs_average_t_o{i}(end,:)';T_t_o{i}(end,:)';film_t_o{i}(end,:)';Q_t_o{i}(end,:)';jflux_t_o{i}(end,:)';Phis_t_o{i}(end,:)';Phie_t_o{i}(end,:)';js_t_o{i}(end,:)';app_current_t_o{i}(end)];
end

% Store the array of last results
results.Y                           = y;
results.YP                          = yp;

results.original.Y                  = y_original;
results.original.YP                 = yp_original;

results.original.initialState.Y     = y_original;
results.original.initialState.YP    = yp_original;

results.initialState.Y              = y;
results.initialState.YP             = yp;

% Store simulation time
results.simulation_time             = sim_time;

% Exit reason
results.exit_reason                 = exit_reason;

% Check the type of current applied and store the results.

%Galvanostatic
if(param{1}.AppliedCurrent==1)
    results.appliedCurrent          = param{1}.I * ones(size(t_tot{1},1),1);
    results.original.appliedCurrent = param{1}.I * ones(size(t_tot_original{1},1),1);
    % Variable current profile
elseif(param{1}.AppliedCurrent==2)
    results.appliedCurrent          = param{1}.getCurr(t_tot{1},t0,tf,param{1}.extraData);
    results.original.appliedCurrent = param{1}.getCurr(t_tot_original{1},t0,tf,param{1}.extraData);
else
    % Potentiostatic
    results.appliedCurrent          = app_current_t{1};
    results.original.appliedCurrent = app_current_t_o{1};
end
end

function estimate = SOCestimation(t,t0,tf,param,ce_t,cs_bar_t,cs_star_t,Phie_t,Phis_t,jflux_t,T_t)
% Build the states structure which will be passed to the function
states.ce           = ce_t(end,:);
states.cs_average   = cs_bar_t(end,:);
states.cs_surface   = cs_star_t(end,:);
states.Phie         = Phie_t(end,:);
states.Phis         = Phis_t(end,:);
states.ionic_flux   = jflux_t(end,:);
states.Temperature  = T_t(end,:);
% Call the estimation procedure
estimate = param.SOC_estimation_function(t,t0,tf,states,param.extraData,param);
end


% This function is used to get a measurement of the SOC according to the
% internal states. This function assumes that all the states are
% measurable.
function Sout = internalSOCestimate(cs_average_t,param,i)
% Check if Fick's law of diffusion is used. This is required to define the
% correct way how to evaluate the SOC.
if(param{i}.SolidPhaseDiffusion~=3)
    cs_average = cs_average_t{i}(end,param{i}.Np+1:end);
else
    start_index = param{i}.Nr_p*param{i}.Np+1;
    end_index   = start_index+param{i}.Nr_n-1;
    cs_average  = zeros(param{i}.Nn,1);
    for n=1:param{i}.Nn
        cs_average(n)   = 1/param{i}.Rp_n*(param{i}.Rp_n/param{i}.Nr_n)*sum(cs_average_t{i}(end,start_index:end_index));
        start_index     = end_index + 1;
        end_index       = end_index + param{i}.Nr_n;
    end
end
Csout  = sum(cs_average);
Sout   = 100*(1/param{i}.len_n*(param{i}.len_n/(param{i}.Nn))*Csout/param{i}.cs_max(3));
end