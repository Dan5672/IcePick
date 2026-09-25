# Prints each argument it receives on its own line, wrapped in <>, so tests can
# check how a command line was split into arguments.
foreach ($a in $args) { Write-Output "<$a>" }
