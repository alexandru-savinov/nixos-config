---
name: self-improvement
description: "Captures learnings, errors, and corrections to enable continuous improvement. Use when: (1) A command or operation fails unexpectedly, (2) User corrects Claude ('No, that's wrong...', 'Actually...'), (3) User requests a capability that doesn't exist, (4) An external API or tool fails, (5) Claude realizes its knowledge is outdated or incorrect, (6) A better approach is discovered for a recurring task. Also review learnings before major tasks."
---

# Self-Improvement Skill

Log learnings and errors to markdown files for continuous improvement.

## Quick Reference

| Situation | Action |
|-----------|--------|
| Command/operation fails | Log to `.learnings/ERRORS.md` |
| User corrects you | Log to `.learnings/LEARNINGS.md` with category `correction` |
| User wants missing feature | Log to `.learnings/FEATURE_REQUESTS.md` |
| API/external tool fails | Log to `.learnings/ERRORS.md` with integration details |
| Knowledge was outdated | Log to `.learnings/LEARNINGS.md` with category `knowledge_gap` |
| Found better approach | Log to `.learnings/LEARNINGS.md` with category `best_practice` |
| Broadly applicable learning | Promote to `AGENTS.md` or `TOOLS.md` |

## Log Formats

**LEARNINGS.md entry:**
```
### [LEARN-YYYYMMDD-XXX] Title
- **Category**: correction | knowledge_gap | best_practice
- **Context**: Brief description
- **Learning**: What to do differently
- **Date**: YYYY-MM-DD
```

**ERRORS.md entry:**
```
### [ERR-YYYYMMDD-XXX] Title
- **Command**: what failed
- **Error**: error message
- **Fix**: how it was resolved
- **Date**: YYYY-MM-DD
```

**FEATURE_REQUESTS.md entry:**
```
### [FR-YYYYMMDD-XXX] Title
- **Request**: what was asked for
- **Context**: why it was needed
- **Date**: YYYY-MM-DD
```

## References

- `references/examples.md` — full log entry examples
- `references/openclaw-integration.md` — OpenClaw workspace integration details
- `references/hooks-setup.md` — hook configuration guide
- `assets/LEARNINGS.md` — template with promotion guidelines
