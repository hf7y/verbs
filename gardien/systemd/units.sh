# Single source of truth for the systemd --user units gardien installs.
# install.sh and uninstall.sh both source this rather than each keeping
# their own copy of the list -- #41: two lists drift the day a unit is
# renamed or added, and only one script's caller notices.
UNITS="gardien.service gardien.timer gardien-check-stale.service gardien-check-stale.timer gardien-git-hygiene.service gardien-git-hygiene.timer"
TIMERS="gardien.timer gardien-check-stale.timer gardien-git-hygiene.timer"
