function build_closed_loop_trip_cosim()
%BUILD_CLOSED_LOOP_TRIP_COSIM Compatibility entrypoint.
%
% Canonical TripLens semantics are implemented in build_closed_loop_trip_cosim_v2:
%   TRIP     -> associated breaker CLOSED feedback = 0 (OPEN)
%   DERATING -> process boundary/output reduction while breaker remains CLOSED
%
% The historical implementation that treated GT exhaust 150 kg/s / 550 K as a
% Trip has been retired. Those values are now GT DERATING only.
build_closed_loop_trip_cosim_v2();
end
