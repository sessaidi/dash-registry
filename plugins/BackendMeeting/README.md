# Backend Meeting

Your highlights for the backend team meeting ("fait marquant"): what you shipped and what's in
progress over a cycle, grouped into a few themes.

| | |
|---|---|
| Plugin id | `backend-meeting` |
| Version | 1.0.0 |
| Minimum DashKit | 1.5.0 |
| Layer | feature |
| Requires | `github` |
| Uses when installed | `atlassian` |

- **Cycle:** 1 to 10 weeks (2 by default). A new report starts where the previous one ended;
  turn that off in the widget to always cover the last N weeks.
- **Data, read only:** your PRs updated in the range (GitHub search, all your organisations and
  personal repositories), your Jira issues updated in the range, and Dash's notable activity.
  PRs closed without merge are left out. Nothing is written to GitHub or Jira.
- **Report:** themed bullets, then *In chantier* (open PRs, tickets in progress), then a bare
  *Debug & Fix* when at least two small fixes shipped. No ticket ids, links or dates.
- **Kept:** every report in Dash's database (past reports in the widget's history menu), and as
  `fait-marquant-<start>-to-<end>.md` in the output folder set in Settings › Backend Meeting.
