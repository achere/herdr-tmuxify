#!/bin/sh
# check.sh FILE - print herdr's diagnostics for the config file FILE, one per
# line; print nothing when herdr has no complaint. merge.pl and install.sh use
# it to tell whether a change made a config worse.
HERDR_CONFIG_PATH=$1 herdr config check 2>&1 | grep -v '^config:'
exit 0
