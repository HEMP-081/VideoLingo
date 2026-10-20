import sys
from core.pipeline import get_steps

def run(group):
    steps = get_steps(group)
    for i, (label, fn) in enumerate(steps):
        print(f"\n===== STEP {i+1}/{len(steps)}: {label} =====", flush=True)
        fn()
    print(f"\n===== {group} PIPELINE DONE =====", flush=True)

if __name__ == "__main__":
    run(sys.argv[1] if len(sys.argv) > 1 else "subtitles")
