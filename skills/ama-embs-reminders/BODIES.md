# Reminder event bodies

Verbatim runbook text as supplied by the user, except markdown links are rendered as
`<a href="...">text</a>` — Google Calendar's `description` field takes HTML, not
markdown, so a raw `[text](url)` would render literally instead of as a link.

## FNM_FHL (event summary: "FNM/FHL monthly files processed today in ETL")

```
FNM/FHL monthly files arrived yesterday - to be processed by 9:30AM ET today in the AMA ETL.
1. Please watch out for any interruptions or issues in Graylog email alerts and in Orchestrator: <your-orchestrator-dashboard-url>

2. After the everything batch completes and Full AMA run is done on the ETL - as seen in Orchestrator, then monitor the cache update which should kick off at that time. Run it manually if it does not run automatically. The cache update logs its progress <a href="https://yourorg.slack.com/archives/C0XXXXXXXXX">here</a>. If there is an issue, restart the full cache update from the <a href="https://admin.example-app.com/update">admin portal</a>.

3. When done, verify that the dated fields in AMA, such as CPR1_MM_YY show the new date (last month) - Use <a href="https://example-app.com/aggregations/view/00000000-0000-0000-0000-000000000001">this report</a> for FHL/FNM.

4. If the process has been delayed so that the data would only show after 9:30AM ET, send a notification to the clients informing them of the delay
```

## GNM (event summary: "GNM monthly files processed today in ETL")

```
GNM monthly files arrived yesterday - to be processed by 9:30AM ET today in the AMA ETL.
1. Please watch out for any interruptions or issues in Graylog email alerts and in Orchestrator: <your-orchestrator-dashboard-url>

2. After the everything batch completes and Full AMA run is done on the ETL - as seen in Orchestrator, then monitor the cache update which should kick off at that time. Run it manually if it does not run automatically. The cache update logs its progress <a href="https://yourorg.slack.com/archives/C0XXXXXXXXX">here</a>. If there is an issue, restart the full cache update from the <a href="https://admin.example-app.com/update">admin portal</a>.

3. When done, verify that the dated fields in AMA, such as CPR1_MM_YY show the new date (last month) - Use <a href="https://example-app.com/aggregations/view/00000000-0000-0000-0000-000000000002">this report</a> for GNM.

4. If the process has been delayed so that the data would only show after 9:30AM ET, send a notification to the clients informing them of the delay
```
