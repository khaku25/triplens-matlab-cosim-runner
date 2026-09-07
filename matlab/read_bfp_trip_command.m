function cmd = read_bfp_trip_command(commandFile)
%READ_BFP_TRIP_COMMAND Read the canonical TripLens ECMS BFP trip command.
T = readtable(commandFile,"TextType","string","VariableNamingRule","preserve");
required = ["time_s","equipment_id","command","model_input"];
for k=1:numel(required)
    assert(any(string(T.Properties.VariableNames)==required(k)), ...
        "TripLens:BadCommandFile","Command file missing column %s",required(k));
end
mask = upper(T.("equipment_id"))=="FWP-HP" & upper(T.("command"))=="TRIP" & upper(T.("model_input"))=="FWP_HP_TRIP";
rows = T(mask,:);
assert(height(rows)==1,"TripLens:BadBfpCommand","Expected exactly one FWP-HP TRIP / FWP_HP_TRIP command.");
cmd = struct;
cmd.Time_s = double(rows.("time_s")(1));
cmd.EquipmentId = char(rows.("equipment_id")(1));
cmd.Command = char(rows.("command")(1));
cmd.ModelInput = char(rows.("model_input")(1));
if any(string(T.Properties.VariableNames)=="feedback_tag")
    cmd.FeedbackTag = char(rows.("feedback_tag")(1));
else
    cmd.FeedbackTag = "TSP.DRUM.HP.FW_FLOW";
end
end
