# Symphony Local Configuration

User-specific config for pi-symphony. Copy to `LOCAL.md` in the skill directory and fill in.
`LOCAL.md` is gitignored — credentials stay local.

## Linear Access via MCPorter

Linear is accessed through MCPorter. The credentials and OAuth are managed by MCPorter centrally —
once authenticated, it works across all Pi sessions without additional setup.

### MCPorter CLI command pattern

All Linear operations use this pattern:

```bash
npx mcporter --config /Users/thomasmustier/projects/mcporter/config/mcporter.json call linear.<tool> [args...]
```

### Common operations

```bash
MCPC="/Users/thomasmustier/projects/mcporter/config/mcporter.json"

# List issues in a project
npx mcporter --config "$MCPC" call linear.list_issues team=SYM

# Get a specific issue
npx mcporter --config "$MCPC" call linear.get_issue id=SYM-19

# Create/update an issue
npx mcporter --config "$MCPC" call linear.save_issue title="..." team=symphony project=pi-symphony state=Todo 'labels=["symphony"]'

# List projects
npx mcporter --config "$MCPC" call linear.list_projects

# List available tools
npx mcporter --config "$MCPC" list linear
```

### Team Configuration

- Team key: SYM
- Team name: symphony

### Authentication

If Linear auth expires, re-authenticate:
```bash
npx mcporter --config "$MCPC" auth linear
```
