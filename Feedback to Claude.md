# Feedback to Claude

Feedback sent to Anthropic about Claude Code, newest first. Kept here because the
local `/feedback` draft queue is machine-local, capped at 10, and cleared on send —
so the reasoning does not survive there.

---

## 2026-09-18 — Auto mode classifier: policy objection

Filed via `/feedback`. Submitted as an **idea, not a bug**, deliberately: the objection
is to an approach, and filing it as a defect invites it to be closed by tuning a needle.

**Title:** Policy objection: shipping classifier restrictions that break working
workflows to protect users who set no guardrails is the wrong default, and the wrong
way to decide

---

**This is feedback on approach, not a defect report.** Please do not route it as a bug to be closed by tuning a needle. The objection is to how these decisions are being made and shipped.

**The principle:** Claude should not break the workflows of users who are doing exactly what they need to do, in order to serve users who are not. When the classifier is tightened to ban a class of action outright, the cost lands entirely on the careful users — the ones who already built working, guardrailed processes — while the users the change is meant to protect are the ones who never configured anything.

**The asymmetry, which is the crux:** a user who wants an action blocked can add a guardrail in one line, deliberately, at a moment of their choosing, knowing exactly what they are buying. A user whose working process is silently taken away gets none of that. They discover it only when something that worked yesterday stops working, mid-task; then they must diagnose *why* (the denial names no rule and no file, so there is nothing to search for); then they must engineer a workaround; then they must re-verify the workaround is safe. That is a far worse user experience, imposed on exactly the wrong population. Let the people who need the guardrail add the guardrail. It is easy for them and invisible to everyone else.

**"Without checking with the users" is the other half.** These changes arrive with no notice and no announcement. The first signal is a broken workflow. Users who have invested in configuring their environment are the ones most affected and the least consulted — and an explicit permission grant they wrote themselves can be overridden by a classifier decision they were never told about. If a restriction is worth shipping, it is worth telling people it is coming, and worth honoring the configuration they already set.

**What this looks like in practice — one concrete case, offered as illustration, not as the ask:** a routine post-hotfix cleanup (deleting four already-merged branches across four repos) was denied `[Git Destructive]`. The block landed on a batched script containing the commands; the identical commands issued one at a time were allowed. This user runs a substantial custom hook-and-gate layer with its own destructive-action guards — they are precisely the population that HAS set guardrails, which is the point. So the restriction did not prevent the action, it only made the user do it in the less reviewable form, after losing time to diagnosis. That is the shape of the whole complaint: real cost to a careful user, no safety gained.

**What the user said:** "This is not a bug report, but feedback to Claude management. It is not a matter of fixing some small thing. It is the way they do things regarding the classifier that is a problem. Breaking users' workflows to help those who fail to set their own guardrails is not right. Let those who do the wrong thing simply add their guardrails and don't break the workflows of those who do the right thing." And earlier, in full: "1. It breaks functioning workflows in order to try and help those who have failed to put in their own guardrails. 2. In principle, Claude should not break the workflows of those who are doing exactly what they need to do in order to serve those who are not doing what they need to do. 3. It is easy for those who are not doing the right thing to just add their own guardrail. It is not easy for those who have a functioning cleanup task for example, to have to discover that it suddenly stopped working because of Claude's changes to the classifier, then find ways to work around it. Rather, let those who need that guardrail put it in themselves. That is much easier and a far better UX." On first hitting the denial: "What? Refused this. Claude used to be able to do that through this harness, so something changed."

**Repro:** With auto mode active and no deny rule covering git, ask Claude to write a script that loops over repos deleting already-merged branches: denied. Issue the identical commands one at a time: allowed. The inconsistency between the two forms, not the denial itself, is what to look at.

**Evidence:** Denial text named no rule and no hook script — unlike this user's own gates, which always name theirs, giving them something to search for. Session 158ea91a, 2026-09-18.

---

### Drafting notes (not sent)

Three things were deliberately cut before sending, each because it handed a reader a way
to deflect the argument onto the user's own configuration:

* `Bash(git *)` in `permissions.allow`, named as the grant the classifier overrode.
  Invites "he shouldn't be allowing all git commands," which answers nothing — the same
  commands were permitted in one form and refused in another regardless of any grant.
* "auto mode suspends blanket allow rules, so an explicit permission grant has no
  effect." True and substantive, but carries the same handle in weaker form.
* The repro's config preconditions, restated as "no deny rule covering git" — a fact
  about the reader's setup rather than a config of the user's to critique.

An earlier draft of this feedback was written as a bug report with a narrow spec ask
("let an explicit user allow rule win over the classifier") and was **not** sent. It
misframed a policy objection as a fixable defect, which is precisely the reading the
sent version opens by refusing.
