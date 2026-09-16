# Match Hire — 5-Day Remote AI OS Sprint (Original Brief)

## Objective
Answer this question with a working artifact: Whose recurring workflow did you change, what system did you build, and how did you prove it was better than the previous way of working? You may choose a workflow in content, marketing, branding, sales, recruiting, customer support, finance, research, or operations. We recommend using a real workflow from your own work or someone around you. If access to a real user is difficult, you may use public or synthetic data, but clearly state your assumptions about the user and workflow.

Example directions include: A system that turns research from multiple sources into a campaign brief and execution checklist; A system that creates and quality-checks channel-specific content while preserving brand context; A system that normalizes candidate-submission packages and produces criteria-based review evidence and next actions; A system that connects meeting notes and account context to follow-up emails, tasks, and CRM updates; A system that classifies recurring operational requests, executes the appropriate tools, and records results and exceptions.

The problem may be small. It must be real, recurring, and usable by someone other than you.

## Format
- Duration: five days, Monday through Friday
- Work style: remote
- Recommended commitment: eight hours per day
- Final output: working system + evaluation results + portfolio-ready case study
- Ownership: the candidate owns the problem, tools, scope, schedule, and evaluation method
- Company support: lightweight check-ins when needed

## Daily rhythm

### Day 1: Discover, Map, and Baseline
Observe the real workflow and define the exact bottleneck you can solve within five days.

Expected output:
- Target user and job-to-be-done
- Current workflow map: trigger, input, judgment, tool, approval, output, and exception
- Evidence of pain: frequency, time, rework, errors, interview notes, or observational evidence
- Baseline: time and quality under the manual process or simple ChatGPT use
- Success metric and explicit non-goals
- 8-12 test cases covering representative, edge, and failure scenarios
- v1 scope for Day 5

Key question: Is the problem real, recurring, and measurable against a baseline?

### Day 2: Design the System and Ship v0
Translate the workflow into a system design and make the first happy path work.

Expected output:
- Architecture and end-to-end data flow
- Input/output schemas and data contracts
- Model, tool, storage, and interface choices with rationale
- Human approval points, fallbacks, privacy, and permission boundaries
- Evaluation rubric and pass/fail criteria
- A v0 that moves one real input through the entire flow

Key question: Can this design become a repeatable system rather than a one-time generation?

### Day 3: Build the Working Core
Complete the end-to-end core workflow for a non-developer user.

Expected output:
- A working core flow from trigger to final output
- At least two real data-source or tool integrations
- Validation, structured outputs, logs, and useful error messages
- Configuration and secrets separated from the code or workflow
- One interface: CLI, form, chat command, or simple web UI
- First execution by the target user or a proxy user

Key question: Can someone else run the core workflow when you are not beside them?

### Day 4: Evaluate, Break, and Harden
Deliberately break the system and improve it until its reliability can be explained.

Expected output:
- Full test-set results and baseline comparison
- Appropriate quality, latency, cost, or manual-touch metrics
- At least three failure cases with root-cause analysis
- The necessary combination of retries, fallbacks, validation, confidence indicators, or human approval
- Before-and-after regression results
- Feedback from the target or proxy user and the changes made in response

Key question: Can you explain quality and failure across multiple conditions, not just one successful example?

### Day 5: Handoff, Prove Value, and Present
Package the system so another person can run, operate, and improve it.

Expected output:
- Final live demo, runnable repository, or exported workflow
- One-command or three-step setup guide
- User README and operator runbook
- Documentation for architecture, data flow, evaluation set, results, and limitations
- Five-minute screen-recorded demo
- Portfolio-ready case study
- Adoption and quality metrics for the first two weeks after deployment, plus the next iteration plan

Key question: Can another person understand, run, trust, and improve the system?

## Deliverables

### Working System
- Live URL, runnable repository, exported automation, or reproducible local project
- Private submissions are accepted
- Sample data and an executable core path
- Example configuration with all secrets removed

### Evaluation Package
- 8-12 test cases and their expected behavior
- Baseline and final-system comparison
- Pass/fail results and failure analysis
- Appropriate quality, speed, cost, and human-intervention metrics

### Case Study
- User and problem
- Existing workflow and bottleneck
- Scope decisions and non-goals
- Architecture and major trade-offs
- Work delegated to AI and judgment retained by humans
- Failures, changes, results, and limitations
- Next two-week iteration plan

### AI Collaboration Note
- AI tools used and the role of each tool
- Work delegated to AI
- How you verified AI-generated results
- Important results you rejected or manually corrected
- Core decisions you personally owned
