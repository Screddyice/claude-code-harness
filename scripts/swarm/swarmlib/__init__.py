"""swarm — cross-CLI parallel agent dispatch.

Fans bounded task briefs out to headless worker agents on the OTHER
subscription's CLI (codex workers from Claude Code sessions, claude workers
from Codex sessions), each in an isolated git worktree. Workers edit only;
the engine commits. See the harness README for the full contract.
"""

__version__ = "0.1.0"
