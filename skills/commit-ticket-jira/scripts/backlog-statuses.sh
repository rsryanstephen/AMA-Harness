# Source me. One definition of "started or finished" -- statuses a ticket must NOT be offered
# from the backlog in. backlog-prune-resolved.sh REMOVES tickets in these; backlog-qa-sweep.sh
# must never ADD one. Two copies would let the sweep add what prune deletes.
# Blocked / "on hold" deliberately absent (stay on the page, see prune's header).
BACKLOG_STARTED_STATUSES='"In Progress", Review, QA, "Ready to Test", "Test Complete", Done, Closed, Canceled'
