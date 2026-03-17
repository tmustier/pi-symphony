# Symphony Local Configuration

This file contains user-specific configuration for pi-symphony.
Copy this to `LOCAL.md` (in the skill directory) and fill in your details.
`LOCAL.md` is gitignored — your credentials and setup stay local.

## Linear Access

How this agent should check Linear issues for symphony runs.

### Access Method

<!-- Uncomment and configure ONE of these methods: -->

<!-- Option 1: MCPorter (if you have Linear MCP via MCPorter) -->
<!-- Linear is available via MCPorter. Use: -->
<!-- mcporter action=call selector=linear.list_issues args='{"teamId": "YOUR_TEAM_ID"}' -->
<!-- mcporter action=call selector=linear.get_issue args='{"issueId": "ISSUE-123"}' -->

<!-- Option 2: MCP server -->
<!-- Linear is available as an MCP server. Use the mcp() tool. -->

<!-- Option 3: Direct API -->
<!-- Use curl with the Linear GraphQL API: -->
<!-- curl -s -X POST https://api.linear.app/graphql \
<!--   -H "Authorization: $LINEAR_API_KEY" \
<!--   -H "Content-Type: application/json" \
<!--   -d '{"query": "{ issues(filter: {team: {key: {eq: \"TEAM\"}}}) { nodes { identifier title state { name } } } }"}' -->

### Team Configuration

- Team key: CHANGEME
- Project slug (optional): 

### Common Queries

<!-- Add any project-specific queries, label conventions, or workflow notes here. -->
<!-- Example: "THO issues with the 'symphony' label are orchestrated." -->
