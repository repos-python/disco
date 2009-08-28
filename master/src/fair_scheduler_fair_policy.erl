
-module(fair_scheduler_fair_policy).
-behaviour(gen_server).

-export([start_link/1, init/1, handle_call/3, handle_cast/2, 
        handle_info/2, terminate/2, code_change/3]).

-define(FAIRY_INTERVAL, 1000).

-record(job, {name, prio, cputime, bias, pid}).

start_link(Nodes) ->
        error_logger:info_report([{"Fair scheduler: Fair policy"}]),
        case gen_server:start_link({local, sched_policy}, 
                        fair_scheduler_fair_policy, Nodes, []) of
                {ok, Server} -> {ok, Server};
                {error, {already_started, Server}} -> {ok, Server}
        end.

init(Nodes) ->
        NumCores = lists:sum([C || {_, C} <- Nodes]),
        register(fairy, spawn_link(fun() -> fairness_fairy(NumCores) end)),
        {ok, {gb_trees:empty(), [], NumCores}}.

% messages starting with 'priv' are not part of the public policy api

handle_cast({priv_update_priorities, Priorities}, {Jobs, _, NC}) ->
        % The Jobs tree may have changed while fairy was working.
        % Update only the elements that fairy knew about.
        NewJobs = lists:foldl(fun({JobPid, NewJob}, NJobs) ->
                case gb_trees:lookup(JobPid, NJobs) of
                        none ->
                                NJobs;
                        {value, _} ->
                                gb_trees:update(JobPid, NewJob, NJobs)
                end
        end, Jobs, Priorities),
        % Include all known jobs in the priority queue.
        NewPrioQ = [{Prio, Pid} || #job{pid = Pid, prio = Prio} <- 
                gb_trees:values(NewJobs)],
        {noreply, {NewJobs, lists:keysort(1, NewPrioQ), NC}};

% Cluster topology has changed. Inform the fairy about the new total
% number of cores available.
handle_cast({update_nodes, Nodes}, {Jobs, PrioQ, _}) ->
        NumCores = lists:sum([C || {_, C} <- Nodes]),
        fairy ! {update, NumCores},
        {noreply, {Jobs, PrioQ, NumCores}};

handle_cast({new_job, JobPid, JobName}, {Jobs, PrioQ, NC}) ->
        InitialPrio = -1.0 / lists:max([gb_trees:size(Jobs), 1.0]),
        
        Job = #job{name = JobName, cputime = 0, prio = InitialPrio,
                bias = 0.0, pid = JobPid},

        NewJobs = gb_trees:insert(JobPid, Job, Jobs),
        erlang:monitor(process, Job),
        {noreply, {NewJobs, prioq_insert({InitialPrio, JobPid}, PrioQ), NC}}.

handle_call({next_job, _}, _, {{0, _}, _, _} = S) ->
        {reply, nojobs, S};

% NotJobs lists all jobs that got 'none' reply from the fair_scheduler_job task
% scheduler. We want to skip them.
handle_call({next_job, NotJobs}, _, {Jobs, PrioQ, NC}) ->
        {NextJob, RPrioQ} = dropwhile(PrioQ, [], NotJobs),
        {UJobs, UPrioQ} = bias_priority(
                gb_trees:get(NextJob), RPrioQ, Jobs, NC),
        {reply, {ok, NextJob}, {UJobs, UPrioQ, NC}};

handle_call(priv_get_jobs, _, {Jobs, _, _} = S) ->
        {reply, {ok, Jobs}, S}.

handle_info({'DOWN', _, _, JobPid, _}, {Jobs, PrioQ, NC}) ->
        {noreply, {gb_trees:delete(JobPid, Jobs),
                lists:keydelete(JobPid, 2, PrioQ), NC}}.

dropwhile([JobPid|R], H, NotJobs) ->
        case lists:member(JobPid, NotJobs) of
                false -> {JobPid, lists:reverse(H) ++ R};
                true -> dropwhile(R, [JobPid|H], NotJobs)
        end.

% Bias priority is a cheap trick to estimate a new priority for a job that
% has been just scheduled for running. It is based on the assumption that
% the job actually starts a new task (1 / NumCores increase in its share)
% which might not be always true. Fairness fairy will eventually fix the 
% bias. 
bias_priority(Job, PrioQ, Jobs, NumCores) ->
        JobPid = Job#job.pid,
        Bias = Job#job.bias + 1 / NumCores,
        Prio = Job#job.prio + Bias,
        NPrioQ = prioq_insert({Prio, JobPid}, PrioQ),
        {gb_trees:update(JobPid, Job#job{bias = Bias}, Jobs), NPrioQ}.

% Insert an item to an already sorted list
prioq_insert(Item, R) -> prioq_insert(Item, R, []).
prioq_insert(Item, [], H) -> lists:reverse([Item|H]);
prioq_insert({Prio, _} = Item, [{P, _} = E|R], H) when Prio > P ->
        prioq_insert(Item, R, [E|H]);
prioq_insert(Item, L, H) ->
        lists:reverse(H) ++ [Item|L].

% Fairness Fairy assigns priorities to jobs in real time based on
% the ideal share of resources they should get, and the reality of
% much resources they are occupying in practice.

fairness_fairy(NumCores) ->
        receive
                {update, NewNumCores} ->
                        fairness_fairy(NewNumCores)
        after ?FAIRY_INTERVAL ->
                {ok, Alpha} = application:get_env(fair_scheduler_alpha),
                update_priorities(Alpha, NumCores),
                fairness_fairy(NumCores)
        end.

update_priorities(_, 0) -> ok;
update_priorities(Alpha, NumCores) ->
        {ok, Jobs} = gen_server:call(sched_policy, priv_get_jobs),
        NumJobs = gb_trees:size(Jobs),

        % Get the status of each running job
        Stats = [{Job, X} || {Job, {ok, X}} <- 
                   [{Job, catch gen_server:call(Job#job.pid, get_stats, 100)} ||
                        Job <- gb_trees:values(Jobs)]],
        
        % Each job gets a 1/Nth share of resources by default
        Share = NumCores / lists:max([1, NumJobs]),
        % If a job has fewer tasks than its share would allow, it donates
        % its extra resources to other needy jobs.
        Extra = [Share - NumTasks ||
                        {_, {NumTasks, _}} <- Stats, NumTasks < Share],
        % Extra resources are shared equally among the needy 
        ExtraShare = lists:sum(Extra) / (NumJobs - length(Extra)),

        gen_server:cast(sched_policy, {priv_update_priorities, lists:map(fun
                ({Job, {NumTasks, NumRunning}}) ->
                        MyShare = 
                                if NumTasks < Share ->
                                        NumTasks;
                                true ->
                                        Share + ExtraShare
                                end,
                        % Compute the difference between the ideal fair share
                        % and how much resources the job has actually reserved
                        Deficit = NumRunning / NumCores - MyShare / NumCores,
                        % Job's priority is the exponential moving average
                        % of its deficits over time
                        Prio = Alpha * Deficit + (1 - Alpha) * Job#job.prio,
                        {Job#job.pid, Job#job{prio = Prio, bias = 0,
                                cputime = Job#job.cputime + NumRunning}}
        end, Stats)}).

% callback stubs
terminate(_Reason, _State) -> {}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
