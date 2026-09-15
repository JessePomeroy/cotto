"""Use the server's canonical prompt export or an explicit experiment file."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def add_prompt_arguments(parser):
    parser.add_argument("--prompt", type=Path, help="Cleanup system prompt file; defaults to the server's canonical prompt")
    parser.add_argument("--server", type=Path, default=ROOT / ".build/debug/sotto-server",
                        help="Server executable used to export the canonical default prompt")


def load_cleanup_prompt(arguments):
    if arguments.prompt:
        # Match the canonical CLI export: its final newline is a file delimiter,
        # not part of the system prompt sent by the server.
        prompt = arguments.prompt.read_text().removesuffix("\n")
    else:
        result = subprocess.run([str(arguments.server.resolve()), "--print-default-proofreading-prompt"],
                                capture_output=True, text=True, check=True, timeout=10)
        prompt = result.stdout.removesuffix("\n")
    if not prompt.strip() or "\0" in prompt or len(prompt.encode("utf-8")) > 4096:
        raise ValueError("The cleanup system prompt must be nonempty, contain no NUL, and fit within 4096 bytes")
    return prompt
