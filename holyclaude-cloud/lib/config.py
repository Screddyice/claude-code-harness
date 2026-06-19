"""legion.toml loader with sane defaults."""
from __future__ import annotations

import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path


CONFIG_PATH = Path("legion.toml")


@dataclass
class SwarmConfig:
    # Hard cap on concurrent session/cloud workers (the ones that hit the
    # Anthropic API). Raised from the original 5 → 10; the governor still
    # halves this on a real 429, and local-model overflow workers (Qwen via
    # the backdoor router) run ON TOP of this cap without touching it.
    max_workers: int = 10
    ramp_first_run: bool = True
    human_checkpoint_after_decompose: bool = True
    # "session" (default, Pro rate-limits apply) or "api" (Anthropic API key,
    # costs money but no throttle). Applies to workers, not the orchestrator.
    auth_mode: str = "session"


@dataclass
class BudgetConfig:
    max_dollars_per_hour: float = 0.0
    worker_timeout_minutes: int = 30


@dataclass
class ReconcilerConfig:
    mediator_max_retries: int = 2
    branch_prefix: str = "legion/"
    use_admin_merge: bool = False


@dataclass
class ReviewConfig:
    enabled: bool = True
    categories: list[str] = field(default_factory=lambda: [
        "security",
        "task_adherence",
        "silent_failures",
        "type_design",
        "dead_code",
    ])
    max_review_redispatches: int = 2
    # Where to run the reviewer: "local" | "cloud" | "auto"
    # "auto" = same router as regular workers
    target: str = "local"


@dataclass
class DispatchConfig:
    local_file_threshold: int = 5
    cloud_minutes_threshold: int = 5
    always_cloud_patterns: list[str] = field(default_factory=lambda: [
        r"(?i)scrape",
        r"(?i)browser test",
        r"(?i)long-running",
        r"(?i)benchmark",
    ])


@dataclass
class LocalModelConfig:
    """Overflow workers backed by an on-device model (Qwen via the backdoor
    router on :8083). These spawn as EXTRA workers beyond the session/cloud
    cap when ready tasks are starved — so the Mac absorbs overflow instead of
    legion tapping out on the Pro-session rate limit.
    """
    enabled: bool = True
    # Extra workers beyond the session/cloud cap (current_max_workers).
    max_workers: int = 2
    # Backdoor router endpoint; qwen* model names route to local Ollama.
    base_url: str = "http://localhost:8083"
    # Full-harness-safe default. Do NOT default to 9B — it pins a 36GB Mac.
    default_model: str = "qwen3.5:4b-64k"
    # Optional code-heavy model (e.g. "qwen-coder"). "" = always default_model.
    # The 32B coder is slow in the full harness, so it's opt-in.
    coder_model: str = ""
    # "simple" = only small/trivial overflow tasks go local (recommended);
    # "any" = grab whatever's next in the ready queue.
    offload: str = "simple"
    # A local-model PR that fails CI/review re-dispatches to the real model
    # instead of churning the 4B on something it already couldn't land.
    redispatch_to_real_model: bool = True


@dataclass
class LegionConfig:
    swarm: SwarmConfig = field(default_factory=SwarmConfig)
    budget: BudgetConfig = field(default_factory=BudgetConfig)
    reconciler: ReconcilerConfig = field(default_factory=ReconcilerConfig)
    dispatch: DispatchConfig = field(default_factory=DispatchConfig)
    review: ReviewConfig = field(default_factory=ReviewConfig)
    local_model: LocalModelConfig = field(default_factory=LocalModelConfig)


def load(path: Path = CONFIG_PATH) -> LegionConfig:
    """Load legion.toml; missing file returns all defaults with a warning."""
    if not path.exists():
        print(
            f"warning: {path} not found, using defaults",
            file=sys.stderr,
        )
        return LegionConfig()

    with open(path, "rb") as f:
        raw = tomllib.load(f)

    return LegionConfig(
        swarm=SwarmConfig(**raw.get("swarm", {})),
        budget=BudgetConfig(**raw.get("budget", {})),
        reconciler=ReconcilerConfig(**raw.get("reconciler", {})),
        dispatch=DispatchConfig(**raw.get("dispatch", {})),
        review=ReviewConfig(**raw.get("review", {})),
        local_model=LocalModelConfig(**raw.get("local_model", {})),
    )
